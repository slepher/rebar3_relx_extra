%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 80 -*-
%%% Copyright 2012 Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%---------------------------------------------------------------------------
%%% @author Eric Merritt <ericbmerritt@gmail.com>
%%% @copyright (C) 2012 Erlware, LLC.
%%%
%%% @doc Given a complete built release this provider assembles that release
%%% into a release directory.
-module(rlx_prv_app_assembler).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include_lib("relx/include/relx.hrl").

-define(PROVIDER, app_assembler).
-define(DEPS, [resolve_release]).

%%============================================================================
%% API
%%============================================================================
-spec init(rlx_state:t()) -> {ok, rlx_state:t()}.
init(State) ->
    State1 = rlx_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                             {module, ?MODULE},
                                                             {deps, ?DEPS},
                                                             {hooks, {[], [overlay]}}])),
    {ok, State1}.

%% @doc recursively dig down into the library directories specified in the state
%% looking for OTP Applications
-spec do(rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(State) ->
    print_dev_mode(State),
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    OutputDir = rlx_state:output_dir(State),
    case create_output_dir(OutputDir) of
        ok ->
            case rlx_release:realized(Release) of
                true ->
                    case copy_app_directories_to_output(State, Release, OutputDir) of
                        {ok, State1} ->
                            case rlx_state:debug_info(State1) =:= strip
                                andalso rlx_state:dev_mode(State1) =:= false of
                                true ->
                                    case beam_lib:strip_release(OutputDir) of
                                        {ok, _} ->
                                            {ok, State1};
                                        {error, _, Reason} ->
                                            ?RLX_ERROR({strip_release, Reason})
                                    end;
                                false ->
                                    {ok, State1}
                            end;
                        E ->
                            E
                    end;
                false ->
                    ?RLX_ERROR({unresolved_release, RelName, RelVsn})
            end;
        Error ->
            Error
    end.

-spec format_error(ErrorDetail::term()) -> iolist().
format_error({unresolved_release, RelName, RelVsn}) ->
    io_lib:format("The release has not been resolved ~p-~s", [RelName, RelVsn]);
format_error({ec_file_error, AppDir, TargetDir, E}) ->
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
format_error({specified_erts_does_not_exist, ErtsVersion}) ->
    io_lib:format("Specified version of erts (~s) does not exist",
                  [ErtsVersion]);
format_error({release_script_generation_error, RelFile}) ->
    io_lib:format("Unknown internal release error generating the release file to ~s",
                  [RelFile]);
format_error({release_script_generation_warning, Module, Warnings}) ->
    ["Warnings generating release \s",
     rlx_util:indent(2), Module:format_warning(Warnings)];
format_error({unable_to_create_output_dir, OutputDir}) ->
    io_lib:format("Unable to create output directory (possible permissions issue): ~s",
                  [OutputDir]);
format_error({release_script_generation_error, Module, Errors}) ->
    ["Errors generating release \n",
     rlx_util:indent(2), Module:format_error(Errors)];
format_error({unable_to_make_symlink, AppDir, TargetDir, Reason}) ->
    io_lib:format("Unable to symlink directory ~s to ~s because \n~s~s",
                  [AppDir, TargetDir, rlx_util:indent(2),
                   file:format_error(Reason)]);
format_error(boot_script_generation_error) ->
    "Unknown internal release error generating start_clean.boot";
format_error({boot_script_generation_warning, Module, Warnings}) ->
    ["Warnings generating start_clean.boot \s",
     rlx_util:indent(2), Module:format_warning(Warnings)];
format_error({boot_script_generation_error, Module, Errors}) ->
    ["Errors generating start_clean.boot \n",
     rlx_util:indent(2), Module:format_error(Errors)];
format_error({strip_release, Reason}) ->
    io_lib:format("Stripping debug info from release beam files failed becuase ~s",
                  [beam_lib:format_error(Reason)]);
format_error({rewrite_app_file, AppFile, Error}) ->
    io_lib:format("Unable to rewrite .app file ~s due to ~p", [AppFile, Error]).

%%%===================================================================
%%% Internal Functions
%%%===================================================================
print_dev_mode(State) ->
    case rlx_state:dev_mode(State) of
        true ->
            ec_cmd_log:info(rlx_state:log(State), "Dev mode enabled, release will be symlinked");
        false ->
            ok
    end.

-spec create_output_dir(file:name()) ->
                               ok | {error, Reason::term()}.
create_output_dir(OutputDir) ->
    case ec_file:is_dir(OutputDir) of
        false ->
            case rlx_util:mkdir_p(OutputDir) of
                ok ->
                    ok;
                {error, _} ->
                    ?RLX_ERROR({unable_to_create_output_dir, OutputDir})
            end;
        true ->
            ok
    end.

copy_app_directories_to_output(State, Release, OutputDir) ->
    LibDir = filename:join([OutputDir, "lib"]),
    ok = ec_file:mkdir_p(LibDir),
    IncludeSrc = rlx_state:include_src(State),
    IncludeErts = rlx_state:get(State, include_erts, true),
    Apps = prepare_applications(State, rlx_release:application_details(Release)),
    Result = lists:filter(fun({error, _}) ->
                                  true;
                             (_) ->
                                  false
                          end,
                         lists:flatten(ec_plists:map(fun(App) ->
                                                             copy_app(State, LibDir, App, IncludeSrc, IncludeErts)
                                                     end, Apps))),
    case Result of
        [E | _] ->
            E;
        [] ->
            include_erts(State, Release, OutputDir)
    end.

prepare_applications(State, Apps) ->
    case rlx_state:dev_mode(State) of
        true ->
            [rlx_app_info:link(App, true) || App <- Apps];
        false ->
            Apps
    end.

copy_app(State, LibDir, App, IncludeSrc, IncludeErts) ->
    AppName = erlang:atom_to_list(rlx_app_info:name(App)),
    AppVsn = rlx_app_info:original_vsn(App),
    AppDir = rlx_app_info:dir(App),
    TargetDir = filename:join([LibDir, AppName ++ "-" ++ AppVsn]),
    case AppDir == ec_cnv:to_binary(TargetDir) of
        true ->
            %% No need to do anything here, discover found something already in
            %% a release dir
            ok;
        false ->
            case IncludeErts of
                false ->
                    case is_erts_lib(AppDir) of
                        true ->
                            [];
                        false ->
                            copy_app_(State, App, AppDir, TargetDir, IncludeSrc)
                    end;
                _ ->
                    copy_app_(State, App, AppDir, TargetDir, IncludeSrc)
            end
    end.

is_erts_lib(Dir) ->
    lists:prefix(filename:split(list_to_binary(code:lib_dir())), filename:split(Dir)).

copy_app_(State, App, AppDir, TargetDir, IncludeSrc) ->
    remove_symlink_or_directory(TargetDir),
    case rlx_app_info:link(App) of
        true ->
            link_directory(AppDir, TargetDir),
            rewrite_app_file(State, App, AppDir);
        false ->
            copy_directory(State, App, AppDir, TargetDir, IncludeSrc),
            rewrite_app_file(State, App, TargetDir)
    end.

%% If excluded apps exist in this App's applications list we must write a new .app
rewrite_app_file(State, App, TargetDir) ->
    Name = rlx_app_info:name(App),
    ActiveDeps = rlx_app_info:active_deps(App),
    IncludedDeps = rlx_app_info:library_deps(App),
    AppFile = filename:join([TargetDir, "ebin", ec_cnv:to_list(Name) ++ ".app"]),
    {ok, [{application, AppName, AppData0}]} = file:consult(AppFile),
    OldActiveDeps = proplists:get_value(applications, AppData0, []),
    OldIncludedDeps = proplists:get_value(included_applications, AppData0, []),
    OldModules = proplists:get_value(modules, AppData0, []),
    ExcludedModules = proplists:get_value(Name,
                                          rlx_state:exclude_modules(State), []),

    %% maybe replace excluded apps
    AppData2 =
        case {OldActiveDeps, OldIncludedDeps} of
            {ActiveDeps, IncludedDeps} ->
                AppData0;
            _ ->
                AppData1 = lists:keyreplace(applications
                                           ,1
                                           ,AppData0
                                           ,{applications, ActiveDeps}),
                lists:keyreplace(included_applications
                                 ,1
                                 ,AppData1
                                 ,{included_applications, IncludedDeps})
        end,
    %% maybe replace excluded modules
    AppData3 =
        case ExcludedModules of
            [] -> AppData2;
            _ ->
                lists:keyreplace(modules
                                 ,1
                                 ,AppData2
                                 ,{modules, OldModules -- ExcludedModules})
        end,
    Spec = [{application, AppName, AppData3}],
    case write_file_if_contents_differ(AppFile, Spec) of
        ok -> ok;
        Error -> ?RLX_ERROR({rewrite_app_file, AppFile, Error})
    end.

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
    case ec_file:is_symlink(TargetDir) of
        true ->
            ec_file:remove(TargetDir);
        false ->
            case ec_file:is_dir(TargetDir) of
                true ->
                    ok = ec_file:remove(TargetDir, [recursive]);
                false ->
                    ok
            end
    end.

link_directory(AppDir, TargetDir) ->
    case rlx_util:symlink_or_copy(AppDir, TargetDir) of
        {error, Reason} ->
            ?RLX_ERROR({unable_to_make_symlink, AppDir, TargetDir, Reason});
        ok ->
            ok
    end.

copy_directory(State, App, AppDir, TargetDir, IncludeSrc) ->
    [copy_dir(State, App, AppDir, TargetDir, SubDir)
    || SubDir <- ["ebin",
                  "include",
                  "priv",
                  "lib" |
                  case IncludeSrc of
                      true ->
                          ["src",
                           "c_src"];
                      false ->
                          []
                  end]].

copy_dir(State, App, AppDir, TargetDir, SubDir) ->
    SubSource = filename:join(AppDir, SubDir),
    SubTarget = filename:join(TargetDir, SubDir),
    case ec_file:is_dir(SubSource) of
        true ->
            ok = rlx_util:mkdir_p(SubTarget),
            %% get a list of the modules to be excluded from this app
            AppName = rlx_app_info:name(App),
            ExcludedModules = proplists:get_value(AppName, rlx_state:exclude_modules(State),
                                                  []),
            ExcludedFiles = [filename:join([binary_to_list(SubSource), 
                                            atom_to_list(M) ++ ".beam"]) ||
                                M <- ExcludedModules],
            case copy_dir(SubSource, SubTarget, ExcludedFiles) of
                {error, E} ->
                    ?RLX_ERROR({ec_file_error, AppDir, SubTarget, E});
                ok ->
                    ok
            end;
        false ->
            ok
    end.

%% no files are excluded, just copy the whole dir
copy_dir(SourceDir, TargetDir, []) ->
     case ec_file:copy(SourceDir, TargetDir, [recursive, {file_info, [mode, time]}]) of
        {error, E} -> {error, E};
        ok ->
            ok
    end;
copy_dir(SourceDir, TargetDir, ExcludeFiles) ->
    SourceFiles = filelib:wildcard(
                    filename:join([binary_to_list(SourceDir), "*"])),
    lists:foreach(fun(F) ->
                    ok = ec_file:copy(F,
                                      filename:join([TargetDir,
                                                     filename:basename(F)]), [{file_info, [mode, time]}])
                  end, SourceFiles -- ExcludeFiles).

%% @doc Optionally add erts directory to release, if defined.
-spec include_erts(rlx_state:t(), rlx_release:t(),  file:name()) ->
                          {ok, rlx_state:t()} | relx:error().
include_erts(State, Release, OutputDir) ->
    Prefix = case rlx_state:get(State, include_erts, true) of
                 false ->
                     false;
                 true ->
                     code:root_dir();
                 P ->
                     filename:absname(P)
    end,

    case Prefix of
        false ->
            {ok, State};
        _ ->
            ec_cmd_log:info(rlx_state:log(State), "Including Erts from ~s~n", [Prefix]),
            ErtsVersion = rlx_release:erts(Release),
            ErtsDir = filename:join([Prefix, "erts-" ++ ErtsVersion]),
            LocalErts = filename:join([OutputDir, "erts-" ++ ErtsVersion]),
            {OsFamily, _OsName} = rlx_util:os_type(State),
            case ec_file:is_dir(ErtsDir) of
                false ->
                    ?RLX_ERROR({specified_erts_does_not_exist, ErtsVersion});
                true ->
                    ok = ec_file:mkdir_p(LocalErts),
                    ok = ec_file:copy(ErtsDir, LocalErts, [recursive, {file_info, [mode, time]}]),
                    case OsFamily of
                        unix ->
                            Erl = filename:join([LocalErts, "bin", "erl"]),
                            ok = ec_file:remove(Erl),
                            ok = file:write_file(Erl, erl_script(ErtsVersion)),
                            ok = file:change_mode(Erl, 8#755);
                        win32 ->
                            ErlIni = filename:join([LocalErts, "bin", "erl.ini"]),
                            ok = ec_file:remove(ErlIni),
                            ok = file:write_file(ErlIni, erl_ini(OutputDir, ErtsVersion))
                    end,

                    %% delete erts src if the user requested it not be included
                    case rlx_state:include_src(State) of
                        true -> ok;
                        false ->
                            SrcDir = filename:join([LocalErts, "src"]),
                            %% ensure the src folder exists before deletion
                            case ec_file:exists(SrcDir) of
                              true -> ok = ec_file:remove(SrcDir, [recursive]);
                              false -> ok
                            end
                    end,
                    {ok, State}
            end
    end.

erl_script(ErtsVsn) ->
    render(erl_script, [{erts_vsn, ErtsVsn}]).

erl_ini(OutputDir, ErtsVsn) ->
    ErtsDirName = rlx_string:concat("erts-", ErtsVsn),
    BinDir = filename:join([OutputDir, ErtsDirName, bin]),
    render(erl_ini, [{bin_dir, BinDir}, {output_dir, OutputDir}]).

render(Template, Data) ->
    Files = rlx_util:template_files(),
    Tpl = rlx_util:load_file(Files, escript, atom_to_list(Template)),
    {ok, Content} = rlx_util:render(Tpl, Data),
    Content.
