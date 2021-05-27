-module(rlx_ext_assemble).

-export([do/2,
         format_error/1]).

-include_lib("relx/src/relx.hrl").
-include_lib("relx/src/rlx_log.hrl").
-include_lib("kernel/include/file.hrl").

do(Release, State) ->
    RelName = rlx_release:name(Release),
    ?log_info("Assembling release ~p-~s...", [RelName, rlx_release:vsn(Release)]),
    OutputDir = filename:join(rlx_state:base_output_dir(State), RelName),
    ?log_debug("Release output dir ~s", [OutputDir]),
    ok = create_output_dir(OutputDir),
    ok = copy_app_directories_to_output(Release, OutputDir, State),

    {ok, State1} = create_release(State, Release, OutputDir),

    ?log_info("Release successfully assembled: ~s", [rlx_file_utils:print_path(OutputDir)]),

    %% don't strip the release in debug mode since that would strip
    %% the beams symlinked to and no one wants that
    case rlx_state:debug_info(State1) =:= strip
        andalso rlx_state:mode(State1) =/= dev of
        true ->
            ?log_debug("Stripping release beam files", []),
            %% make *.beam to be writeable for strip.
            ModeChangedFiles = [ 
                OrigFileMode
                || File <- rlx_file_utils:wildcard_paths([OutputDir ++ "/**/*.beam"]), 
                    OrigFileMode <- begin
                        {ok, #file_info{mode = OrigMode}} = file:read_file_info(File), 
                        case OrigMode band 8#0200 =/= 8#0200 of
                            true ->
                                file:change_mode(File, OrigMode bor 8#0200),
                                [{File, OrigMode}];
                            false -> []
                        end
                    end
                ],
            try beam_lib:strip_release(OutputDir) of
                {ok, _} ->
                    {ok, State1};
                {error, _, Reason} ->
                    erlang:error(?RLX_ERROR({strip_release, Reason}))
            after
                %% revert file permissions after strip.
                [ file:change_mode(File, OrigMode) 
                    || {File, OrigMode} <- ModeChangedFiles ]
            end;
        false ->
            {ok, State1}
    end.

%% internal functions

-spec create_output_dir(file:name()) -> ok.
create_output_dir(OutputDir) ->
    case rlx_file_utils:is_dir(OutputDir) of
        false ->
            case rlx_file_utils:mkdir_p(OutputDir) of
                ok ->
                    ok;
                {error, _} ->
                    erlang:error(?RLX_ERROR({unable_to_create_output_dir, OutputDir}))
            end;
        true ->
            ok
    end.

copy_app_directories_to_output(Release, OutputDir, State) ->
    LibDir = filename:join([OutputDir, "lib"]),
    ok = rlx_file_utils:mkdir_p(LibDir),
    IncludeSystemLibs = rlx_state:system_libs(State),
    Apps = prepare_applications(State, rlx_release:applications(Release)),
    [copy_app(State, LibDir, App, IncludeSystemLibs) || App <- Apps],
    ok.

prepare_applications(State, Apps) ->
    case rlx_state:mode(State) of
        dev ->
            [rlx_app_info:link(App, true) || App <- Apps];
        _ ->
            Apps
    end.

copy_app(State, LibDir, App, IncludeSystemLibs) ->
    AppName = erlang:atom_to_list(rlx_app_info:name(App)),
    AppVsn = rlx_app_info:vsn(App),
    AppDir = rlx_app_info:dir(App),
    TargetDir = filename:join([LibDir, AppName ++ "-" ++ AppVsn]),
    case AppDir == rlx_util:to_binary(TargetDir) of
        true ->
            %% No need to do anything here, discover found something already in
            %% a release dir
            ok;
        false ->
            case IncludeSystemLibs of
                false ->
                    case is_system_lib(AppDir) of
                        true ->
                            ok;
                        false ->
                            copy_app_(State, App, AppDir, TargetDir)
                    end;
                _ ->
                    copy_app_(State, App, AppDir, TargetDir)
            end
    end.

%% TODO: support override system lib dir that isn't code:lib_dir/0
is_system_lib(Dir) ->
    lists:prefix(filename:split(code:lib_dir()), filename:split(rlx_string:to_list(Dir))).

copy_app_(State, App, AppDir, TargetDir) ->
    remove_symlink_or_directory(TargetDir),
    case rlx_app_info:link(App) of
        true ->
            link_directory(AppDir, TargetDir),
            rewrite_app_file(State, App, AppDir);
        false ->
            copy_directory(State, App, AppDir, TargetDir),
            rewrite_app_file(State, App, TargetDir)
    end.

%% If excluded apps or modules exist in this App's applications list we must write a new .app
rewrite_app_file(State, App, TargetDir) ->
    Name = rlx_app_info:name(App),
    Applications = rlx_app_info:applications(App),
    IncludedApplications = rlx_app_info:included_applications(App),

    %% TODO: should really read this in when creating rlx_app:t() and keep it
    AppFile = filename:join([TargetDir, "ebin", [Name, ".app"]]),
    {ok, [{application, AppName, AppData0}]} = file:consult(AppFile),

    %% maybe replace excluded apps
    AppData1 = maybe_exclude_apps(Applications, IncludedApplications,
                                  AppData0, rlx_state:exclude_apps(State)),

    AppData2 = maybe_exclude_modules(AppData1, proplists:get_value(Name,
                                                                   rlx_state:exclude_modules(State),
                                                                   [])),

    Spec = [{application, AppName, AppData2}],
    case write_file_if_contents_differ(AppFile, Spec) of
        ok ->
            ok;
        Error ->
            erlang:error(?RLX_ERROR({rewrite_app_file, AppFile, Error}))
    end.

maybe_exclude_apps(_Applications, _IncludedApplications, AppData, []) ->
    AppData;
maybe_exclude_apps(Applications, IncludedApplications, AppData, ExcludeApps) ->
    AppData1 = lists:keyreplace(applications,
                                1,
                                AppData,
                                {applications, Applications -- ExcludeApps}),
    lists:keyreplace(included_applications,
                     1,
                     AppData1,
                     {included_applications, IncludedApplications -- ExcludeApps}).

maybe_exclude_modules(AppData, []) ->
    AppData;
maybe_exclude_modules(AppData, ExcludeModules) ->
    Modules = proplists:get_value(modules, AppData, []),
    lists:keyreplace(modules,
                     1,
                     AppData,
                     {modules, Modules -- ExcludeModules}).

write_file_if_contents_differ(Filename, Spec) ->
    ToWrite = io_lib:format("~p.\n", Spec),
    case file:consult(Filename) of
        {ok, Spec} ->
            ok;
        {ok,  _} ->
            file:write_file(Filename, ToWrite);
        {error,  _} ->
            file:write_file(Filename, ToWrite)
    end.

remove_symlink_or_directory(TargetDir) ->
    case rlx_file_utils:is_symlink(TargetDir) of
        true ->
            ok = rlx_file_utils:remove(TargetDir);
        false ->
            case rlx_file_utils:is_dir(TargetDir) of
                true ->
                    ok = rlx_file_utils:remove(TargetDir, [recursive]);
                false ->
                    ok
            end
    end.

link_directory(AppDir, TargetDir) ->
    case rlx_file_utils:symlink_or_copy(AppDir, TargetDir) of
        {error, Reason} ->
            erlang:error(?RLX_ERROR({unable_to_make_symlink, AppDir, TargetDir, Reason}));
        ok ->
            ok
    end.

copy_directory(State, App, AppDir, TargetDir) ->
    [copy_dir(State, App, AppDir, TargetDir, SubDir)
    || SubDir <- ["ebin",
                  "include",
                  "priv" |
                  case include_src_or_default(State) of
                      true ->
                          ["src",
                           "lib",
                           "c_src"];
                      false ->
                          []
                  end]].

copy_dir(State, App, AppDir, TargetDir, SubDir) ->
    SubSource = filename:join(AppDir, SubDir),
    SubTarget = filename:join(TargetDir, SubDir),
    case rlx_file_utils:is_dir(SubSource) of
        true ->
            ok = rlx_file_utils:mkdir_p(SubTarget),
            %% get a list of the modules to be excluded from this app
            AppName = rlx_app_info:name(App),
            ExcludedModules = proplists:get_value(AppName, rlx_state:exclude_modules(State),
                                                  []),
            ExcludedFiles = [filename:join([rlx_util:to_string(SubSource),
                                            atom_to_list(M) ++ ".beam"]) ||
                                M <- ExcludedModules],
            case copy_dir(SubSource, SubTarget, ExcludedFiles) of
                {error, E} ->
                    erlang:error(?RLX_ERROR({rlx_file_utils_error, AppDir, SubTarget, E}));
                ok ->
                    ok
            end;
        false ->
            ok
    end.

%% no files are excluded, just copy the whole dir
copy_dir(SourceDir, TargetDir, []) ->
     case rlx_file_utils:copy(SourceDir, TargetDir, [recursive, {file_info, [mode, time]}]) of
        {error, E} -> {error, E};
        ok ->
            ok
    end;
copy_dir(SourceDir, TargetDir, ExcludeFiles) ->
    SourceFiles = filelib:wildcard(
                    filename:join([rlx_util:to_string(SourceDir), "*"])),
    lists:foreach(fun(F) ->
                    ok = rlx_file_utils:copy(F,
                                      filename:join([TargetDir,
                                                     filename:basename(F)]), [recursive, {file_info, [mode, time]}])
                  end, SourceFiles -- ExcludeFiles).

create_release(State0, Release0, OutputDir) ->
    ReleaseDir = rlx_util:release_output_dir(State0, Release0),
    ReleaseFile = filename:join([ReleaseDir, [rlx_release:name(Release0), ".rel"]]),
    ok = rlx_file_utils:mkdir_p(ReleaseDir),
    Release1 = rlx_release:relfile(Release0, ReleaseFile),
    State1 = rlx_state:update_realized_release(State0, Release1),

    ReleaseSpec = rlx_release:metadata(Release1),

    ok = rlx_file_utils:write_term(ReleaseFile, ReleaseSpec),
    include_erts(State1, Release1, OutputDir, ReleaseDir),
    {ok, State1}.

%% @doc Optionally add erts directory to release, if defined.
-spec include_erts(rlx_state:t(), rlx_release:t(),  file:name(), file:name()) -> ok.
include_erts(State, Release, OutputDir, RelDir) ->
    Prefix = case rlx_state:include_erts(State) of
                 false ->
                     false;
                 true ->
                     code:root_dir();
                 P ->
                     filename:absname(P)
    end,

    case Prefix of
        false ->
            make_boot_script(State, Release, OutputDir, RelDir);
        _ ->
            ?log_debug("Including Erts from ~s", [Prefix]),
            ErtsVersion = rlx_release:erts(Release),
            ErtsBinDir = filename:join([Prefix, "erts-" ++ ErtsVersion, "bin"]),
            LocalErtsBin = filename:join([OutputDir, "erts-" ++ ErtsVersion, "bin"]),
            {OsFamily, _OsName} = rlx_util:os_type(State),
            case rlx_file_utils:is_dir(ErtsBinDir) of
                false ->
                    erlang:error(?RLX_ERROR({specified_erts_does_not_exist, Prefix, ErtsVersion}));
                true ->
                    ok = rlx_file_utils:mkdir_p(LocalErtsBin),
                    ok = rlx_file_utils:copy(ErtsBinDir, LocalErtsBin,
                                             [recursive, {file_info, [mode, time]}]),

                    case OsFamily of
                        unix ->
                            DynErl = filename:join([LocalErtsBin, "dyn_erl"]),
                            Erl = filename:join([LocalErtsBin, "erl"]),
                            rlx_file_utils:copy(DynErl, Erl);
                        win32 ->
                            DynErl = filename:join([LocalErtsBin, "dyn_erl.ini"]),
                            Erl = filename:join([LocalErtsBin, "erl.ini"]),
                            rlx_file_utils:copy(DynErl, Erl)
                    end,

                    %% drop yielding_c_fun binary if it exists
                    %% it is large (1.1MB) and only used at compile time
                    _ = rlx_file_utils:remove(filename:join([LocalErtsBin, "yielding_c_fun"])),

                    make_boot_script(State, Release, OutputDir, RelDir)
            end
    end.

-spec make_boot_script(rlx_state:t(), rlx_release:t(), file:name(), file:name()) -> ok.
make_boot_script(State, Release, OutputDir, RelDir) ->
    Paths = [RelDir | rlx_util:get_code_paths(Release, OutputDir)],
    Options = [{path, Paths},
               {outdir, RelDir},
               {variables, make_boot_script_variables(Release, State)},
               silent | make_script_options(State)],
    Name = atom_to_list(rlx_release:name(Release)),
    IsRelxSasl = rlx_state:is_relx_sasl(State),

    %% relx built-in form of systools exref feature
    maybe_check_for_undefined_functions(State, Release),

    case make_start_script(Name, RelDir, Options, IsRelxSasl) of
        Result when Result =:= ok orelse (is_tuple(Result) andalso
                                          element(1, Result) =:= ok) ->
            maybe_print_warnings(Result),
            ?log_debug("release start script created"),
            create_RELEASES(State, Release, OutputDir),
            create_no_dot_erlang(RelDir, OutputDir, Options, State),
            create_start_clean(RelDir, OutputDir, Options, State);
        error ->
            ReleaseFile = filename:join([RelDir, [Name, ".rel"]]),
            erlang:error(?RLX_ERROR({release_script_generation_error, ReleaseFile}));
        {error, Module, Error} ->
            erlang:error(?RLX_ERROR({release_script_generation_error, Module, Error}))
    end.

maybe_check_for_undefined_functions(State, Release) ->
    case rlx_state:check_for_undefined_functions(State) of
        true ->
            maybe_check_for_undefined_functions_(State, Release);
        _ ->
            ok
    end.

maybe_check_for_undefined_functions_(State, Release) ->
    Rf = rlx_release:name(Release),
    try xref:start(Rf, [{xref_mode, functions}]) of
        {ok, Pid} when is_pid(Pid) ->
            % Link to ensure internal errors don't go unnoticed.
            link(Pid),

            %% for every app in the release add it to the xref apps to be 
            %% analyzed if it is a project app as specified by rebar3.
            add_project_apps_to_xref(Rf, rlx_release:app_specs(Release), State),

            %% without adding the erts application there will be warnings about 
            %% missing functions from the preloaded modules even though they 
            %% are in the runtime.
            ErtsApp = code:lib_dir(erts, ebin),

            %% xref library path is what is searched for functions used by the 
            %% project apps. 
            %% we only add applications depended on by the release so that we
            %% catch modules not included in the release to warn the user about.
            CodePath = 
                [ErtsApp | [filename:join(rlx_app_info:dir(App), "ebin") 
                    || App <- rlx_release:applications(Release)]],
            _ = xref:set_library_path(Rf, CodePath),

            %% check for undefined function calls from project apps in the 
            %% release
            case xref:analyze(Rf, undefined_function_calls) of
                {ok, Warnings} ->
                    format_xref_warning(Warnings);
                {error, _} = Error ->
                    ?log_warn(
                        "Error running xref analyze: ~s", 
                        [xref:format_error(Error)])
            end
    after
        %% Even if the code crashes above, always ensure the xref server is 
        %% stopped.
        stopped = xref:stop(Rf)
    end.

add_project_apps_to_xref(_Rf, [], _) ->
    ok;
add_project_apps_to_xref(Rf, [AppSpec | Rest], State) ->
    case maps:find(element(1, AppSpec), rlx_state:available_apps(State)) of
        {ok, App=#{app_type := project}} ->
            case xref:add_application(
                    Rf,
                    rlx_app_info:dir(App),
                    [{name, rlx_app_info:name(App)}, {warnings, false}]) 
            of
                {ok, _} ->
                    ok;
                {error, _} = Error ->
                    ?log_warn("Error adding application ~s to xref context: ~s",
                              [rlx_app_info:name(App), xref:format_error(Error)])
            end;
        _ ->
            ok
    end,
    add_project_apps_to_xref(Rf, Rest, State).

format_xref_warning([]) ->
    ok;
format_xref_warning(Warnings) ->
    ?log_warn("There are missing function calls in the release.", []),
    ?log_warn("Make sure all applications needed at runtime are included in the release.", []),
    lists:map(fun({{M1, F1, A1}, {M2, F2, A2}}) ->
                      ?log_warn("~w:~tw/~w calls undefined function ~w:~tw/~w",
                                [M1, F1, A1, M2, F2, A2])
              end, Warnings).

%% setup options for warnings as errors, src_tests and exref
make_script_options(State) ->
    IncludeSrc = include_src_or_default(State),
    WarningsAsErrors = rlx_state:warnings_as_errors(State),
    SrcTests = rlx_state:src_tests(State),
    [Key || {Key, true} <- [{warnings_as_errors, WarningsAsErrors},
                            {src_tests, SrcTests andalso IncludeSrc}]]
        ++ case rlx_state:exref(State) of
               true ->
                   [exref];
               Apps when is_list(Apps) ->
                   [{exref, Apps}];
               _ ->
                   []
           end.

%% when running `release' the default is to include src so `src_tests' can do checks
include_src_or_default(State) ->
    case rlx_state:include_src(State) of
        undefined ->
            true;
        IncludeSrc ->
            IncludeSrc
    end.

make_start_script(Name, RelDir, Options, IsRelxSasl) ->
    case IsRelxSasl of
        true ->
            %% systools in sasl version 3.5 and above has the `script_name' option
            systools:make_script(Name, [{script_name, "start"} | Options]);
        false ->
            case systools:make_script(Name, Options) of
                Result when Result =:= ok orelse (is_tuple(Result) andalso
                                          element(1, Result) =:= ok) ->
                    copy_to_start(RelDir, Name),
                    Result;
                Error ->
                    Error
            end
    end.

%% systools:make_script in sasl <3.5 do not support `script_name'
%% so the `Name.boot' file must be manually copied to `start.boot'
copy_to_start(RelDir, Name) ->
    BootFile = [Name, ".boot"],
    case rlx_file_utils:copy(filename:join([RelDir, BootFile]),
                             filename:join(RelDir, "start.boot")) of
        ok ->
            ok;
        {error, Reason} ->
            %% it isn't absolutely necesary for start.boot to exist so just warn
            ?log_warn("Unable to copy boot file ~s to start.boot: ~p", [BootFile, Reason]),
            ok
    end.

maybe_print_warnings({ok, Module, Warnings}) when Warnings =/= [] ->
    FormattedWarnings = unicode:characters_to_list(Module:format_warning(Warnings)),
    Trimmed = rlx_string:trim(FormattedWarnings, trailing, "\n"),
    ?log_warn("Warnings generating release:~n~s", [Trimmed]);
maybe_print_warnings(_) ->
    ok.

make_boot_script_variables(Release, State) ->
    % A boot variable is needed when {system_libs, false} and the application
    % directories are split between the release/lib directory and the erlang
    % install directory on the target host.
    % The built-in $ROOT variable points to the erts directory on Windows
    % (dictated by erl.ini [erlang] Rootdir=) and so a boot variable is made
    % pointing to the release directory
    % On non-Windows, $ROOT is set by the ROOTDIR environment variable as the
    % release directory, so a boot variable is made pointing to the erts
    % directory.
    % NOTE the boot variable can point to either the release/erts root directory
    % or the release/erts lib directory, as long as the usage here matches the
    % usage used in the start up scripts
    case {os:type(), rlx_state:system_libs(State)} of
        {{win32, _}, false} ->
            [{"RELEASE_DIR", filename:join(rlx_state:base_output_dir(State),
                                           rlx_release:name(Release))}];
        {{win32, _}, true} ->
            [];
        _ ->
            [{"SYSTEM_LIB_DIR", code:lib_dir()}]
    end.

create_no_dot_erlang(RelDir, OutputDir, Options, _State) ->
    create_other_boot_file(RelDir, [no_dot_erlang | Options], "no_dot_erlang"),
    copy_boot_to_bin(RelDir, OutputDir, "no_dot_erlang").

create_start_clean(RelDir, _OutputDir, Options, _State) ->
    create_other_boot_file(RelDir, Options, "start_clean").

%% function for creating .boot files for no_dot_erlang and start_clean
create_other_boot_file(RelDir, Options, Name) ->
    case systools:make_script(Name, [{outdir, RelDir},
                                     no_warn_sasl | Options]) of
        Result when Result =:= ok orelse (is_tuple(Result) andalso
                                          element(1, Result) =:= ok) ->
            %% don't need to leave the .rel and .script for these boot files
            rlx_file_utils:remove(filename:join([RelDir, [Name, ".rel"]])),
            rlx_file_utils:remove(filename:join([RelDir, [Name, ".script"]]));
        error ->
            erlang:error(?RLX_ERROR({boot_script_generation_error, Name}));
        {error, Module, Error} ->
            erlang:error(?RLX_ERROR({boot_script_generation_error, Name, Module, Error}))
    end.

%% TODO: What escript is this talking about?
%% escript requires boot files in bin/ and not under the release dir
copy_boot_to_bin(RelDir, OutputDir, Name) ->
    From = filename:join([RelDir, Name++".boot"]),
    To = filename:join([OutputDir, "bin", Name++".boot"]),
    case rlx_file_utils:copy(From, To) of
        ok ->
            ok;
        {error, Reason} ->
            erlang:error({failed_copy_boot_to_bin, From, To, Reason})
    end.

%% this file must exist for release_handler functions to work
create_RELEASES(State, Release, OutputDir) ->
    case rlx_state:system_libs(State) of
        false ->
            ?log_debug("*WARNING* Not creating RELEASES file because system libs are not included "
                       "in the release. The RELEASES file is required before release_handler can be used "
                       "to install a release."),
            %% remove the RELEASES file in case it exists from a previous release build
            _ = rlx_file_utils:remove(filename:join([OutputDir, "releases", "RELEASES"]));
        _ ->
            case create_RELEASES(OutputDir, Release) of
                ok ->
                    ok;
                {error, Reason} ->
                    ?log_debug("*WARNING* Creating RELEASES file failed for reason: ~p "
                               "The RELEASES file is required before release_handler can be used "
                               "to install a release.", [Reason]),
                    ok
            end
    end.

create_RELEASES(OutputDir, Release) ->
    RelName = atom_to_list(rlx_release:name(Release)),
    RelVsn = rlx_release:vsn(Release),
    ErtsVsn = rlx_release:erts(Release),
    Apps = [{Name, Vsn, filename:join("./lib", [Name, "-", Vsn])}
            || #{name := Name,
                 vsn := Vsn,
                 dir := _Dir} <- rlx_release:applications(Release)],

    do_write_release(filename:join(OutputDir, "releases"),
                     {release, RelName, RelVsn, ErtsVsn, Apps, permanent}).

do_write_release(Dir, Release) ->
    case file:open(filename:join(Dir, "RELEASES"), [write,{encoding,utf8}]) of
        {ok, Fd} ->
            ok = io:format(Fd, "%% ~ts~n~tp.~n",
                           [epp:encoding_to_string(utf8), [Release]]),
            ok = file:close(Fd);
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(ErrorDetail::term()) -> iolist().
format_error({failed_copy_boot_to_bin, From, To, Reason}) ->
    io_lib:format("Unable to copy ~s to ~s for reason: ~p", [From, To, Reason]);
format_error({unresolved_release, RelName, RelVsn}) ->
    io_lib:format("The release has not been resolved ~p-~s", [RelName, RelVsn]);
format_error({rlx_file_utils_error, AppDir, TargetDir, E}) ->
    io_lib:format("Unable to copy OTP App from ~s to ~s due to ~p",
                  [AppDir, TargetDir, E]);
format_error({vmargs_does_not_exist, Path}) ->
    io_lib:format("The vm.args file specified for this release (~s) does not exist!",
                  [Path]);
format_error({vmargs_src_does_not_exist, Path}) ->
    io_lib:format("The vm.args.src file specified for this release (~s) does not exist!",
                  [Path]);
format_error({config_does_not_exist, Path}) ->
    io_lib:format("The sys.config file specified for this release (~s) does not exist!",
                  [Path]);
format_error({config_src_does_not_exist, Path}) ->
    io_lib:format("The sys.config.src file specified for this release (~s) does not exist!",
                  [Path]);
format_error({sys_config_parse_error, ConfigPath, Reason}) ->
    io_lib:format("The config file (~s) specified for this release could not be opened or parsed: ~s",
                  [ConfigPath, file:format_error(Reason)]);
format_error({specified_erts_does_not_exist, Prefix, ErtsVersion}) ->
    io_lib:format("Specified version of erts (~s) does not exist under configured directory ~s",
                  [ErtsVersion, Prefix]);
format_error({release_script_generation_error, RelFile}) ->
    io_lib:format("Unknown internal release error generating the release file to ~s",
                  [RelFile]);
format_error({unable_to_create_output_dir, OutputDir}) ->
    io_lib:format("Unable to create output directory (possible permissions issue): ~s",
                  [OutputDir]);
format_error({release_script_generation_error, Module, Errors}) ->
    ["Error generating release: \n", Module:format_error(Errors)];
format_error({unable_to_make_symlink, AppDir, TargetDir, Reason}) ->
    io_lib:format("Unable to symlink directory ~s to ~s because \n~s~s",
                  [AppDir, TargetDir, rlx_util:indent(2),
                   file:format_error(Reason)]);
format_error({boot_script_generation_error, Name}) ->
    io_lib:format("Unknown internal release error generating ~s.boot", [Name]);
format_error({boot_script_generation_error, Name, Module, Errors}) ->
    [io_lib:format("Errors generating ~s.boot: ~n", [Name]),
     rlx_util:indent(2), Module:format_error(Errors)];
format_error({strip_release, Reason}) ->
    io_lib:format("Stripping debug info from release beam files failed: ~s",
                  [beam_lib:format_error(Reason)]);
format_error({rewrite_app_file, AppFile, Error}) ->
    io_lib:format("Unable to rewrite .app file ~s due to ~p",
                  [AppFile, Error]);
format_error({create_RELEASES, Reason}) ->
    io_lib:format("Unable to create RELEASES file needed by release_handler: ~p", [Reason]).
