-module(relx_prv_assemble).

-export([do/2, format_error/1]).

-include("relx_ext.hrl").
-include_lib("kernel/include/file.hrl").

do(Cluster, ExtState) ->
    Release = relx_ext_cluster:solved_clus_release(Cluster),
    State = relx_ext_state:rlx_state(ExtState),
    RelName = rlx_release:name(Release),
    rebar_api:info("Assembling release ~p-~s...", [RelName, rlx_release:vsn(Release)]),
    OutputDir = filename:join(rlx_state:base_output_dir(State), RelName),
    rebar_api:debug("Release output dir ~s", [OutputDir]),
    ok = create_output_dir(OutputDir),
    ok = copy_app_directories_to_output(Release, OutputDir, State),

    ExtState1 = relx_ext_state:rlx_state(ExtState, State),
    %% relx built-in form of systools exref feature
    maybe_check_for_undefined_functions(State, Release),

    rebar_api:info("Release successfully assembled: ~s", [rlx_file_utils:print_path(OutputDir)]),

    %% don't strip the release in debug mode since that would strip
    %% the beams symlinked to and no one wants that
    case rlx_state:debug_info(State) =:= strip
        andalso rlx_state:mode(State) =/= dev of
        true ->
            rebar_api:debug("Stripping release beam files", []),
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
                    {ok, ExtState1};
                {error, _, Reason} ->
                    erlang:error(?RLX_ERROR({strip_release, Reason}))
            after
                %% revert file permissions after strip.
                [ file:change_mode(File, OrigMode) 
                    || {File, OrigMode} <- ModeChangedFiles ]
            end;
        false ->
            {ok, ExtState1}
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
                    rebar_api:warn(
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
                    rebar_api:warn("Error adding application ~s to xref context: ~s",
                                   [rlx_app_info:name(App), xref:format_error(Error)])
            end;
        _ ->
            ok
    end,
    add_project_apps_to_xref(Rf, Rest, State).

format_xref_warning([]) ->
    ok;
format_xref_warning(Warnings) ->
    rebar_api:warn("There are missing function calls in the release.", []),
    rebar_api:warn("Make sure all applications needed at runtime are included in the release.", []),
    lists:map(fun({{M1, F1, A1}, {M2, F2, A2}}) ->
                      rebar_api:warn("~w:~tw/~w calls undefined function ~w:~tw/~w",
                                     [M1, F1, A1, M2, F2, A2])
              end, Warnings).

%% when running `release' the default is to include src so `src_tests' can do checks
include_src_or_default(State) ->
    case rlx_state:include_src(State) of
        undefined ->
            true;
        IncludeSrc ->
            IncludeSrc
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
