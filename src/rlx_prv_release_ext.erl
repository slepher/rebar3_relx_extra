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
-module(rlx_prv_release_ext).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include_lib("relx/include/relx.hrl").

-define(PROVIDER, release_ext).
-define(DEPS, [release]).
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
    io:format("release ext~n"),
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    OutputDir = rlx_state:output_dir(State),
    create_release_info(State, Release, OutputDir),
    {ok, State}.

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
    io_lib:format("Unable to rewrite .app file ~s due to ~p",
                  [AppFile, Error]).

%%%===================================================================
%%% Internal Functions
%%%===================================================================

create_release_info(State0, Release0, OutputDir) ->
    ReleaseDir = rlx_util:release_output_dir(State0, Release0),
    Name = erlang:atom_to_list(rlx_release:name(Release0)),
    ReleaseFile = filename:join([ReleaseDir, Name ++ "_load.rel"]),
    Release1 = rlx_release:relfile(Release0, ReleaseFile),
    ok = ec_file:mkdir_p(ReleaseDir),
    %State1 = rlx_state:update_realized_release(State0, Release1),
    case rlx_release:metadata(Release1) of
        {ok, {release, ErlInfo, ErtsInfo, Apps}} ->
            NApps = 
                lists:map(
                  fun({App, AppVsn}) ->
                          BootApps = [kernel, stdlib, sasl],
                             case lists:member(App, BootApps) of
                                 true ->
                                     {App, AppVsn};
                                 false ->
                                     {App, AppVsn, load}
                             end;
                     (AppInfo) ->
                          AppInfo
                  end, Apps),
            Meta = {release, ErlInfo, ErtsInfo, NApps},
                  
            Options = [{path, [ReleaseDir | rlx_util:get_code_paths(Release1, OutputDir)]},
                       {outdir, ReleaseDir},
                       {variables, make_boot_script_variables(State0)},
                       no_module_tests, silent],
            ok = ec_file:write_term(ReleaseFile, Meta),
            case rlx_util:make_script(Options,
                                      fun(CorrectedOptions) ->
                                              systools:make_script(Name ++ "_load", CorrectedOptions)
                                      end) of

                ok ->
                    ok = ec_file:copy(filename:join([ReleaseDir, Name++"_load.boot"]),
                                      filename:join([OutputDir, "bin", Name++"_load.boot"])),
                    ok = ec_file:copy(filename:join([ReleaseDir, Name++"_load.boot"]),
                                      filename:join([OutputDir, "bin", "boot_load.boot"])),
                    ok;
                error ->
                    ?RLX_ERROR({release_script_generation_error, ReleaseFile});
                {ok, _, []} ->
                    ok = ec_file:copy(filename:join([ReleaseDir, Name++"_load.boot"]),
                                      filename:join([OutputDir, "bin", Name++"_load.boot"])),
                    ok = ec_file:copy(filename:join([ReleaseDir, Name++"_load.boot"]),
                                      filename:join([OutputDir, "bin", "boot_load.boot"])),
                    ok;
                {ok,Module,Warnings} ->
                    ?RLX_ERROR({release_script_generation_warn, Module, Warnings});
                {error,Module,Error} ->
                    ?RLX_ERROR({release_script_generation_error, Module, Error})
            end;
        E ->
            E
    end.

make_boot_script_variables(State) ->
    % A boot variable is needed when {include_erts, false} and the application
    % directories are split between the release/lib directory and the erts/lib
    % directory.
    % The built-in $ROOT variable points to the erts directory on Windows
    % (dictated by erl.ini [erlang] Rootdir=) and so a boot variable is made
    % pointing to the release directory
    % On non-Windows, $ROOT is set by the ROOTDIR environment variable as the
    % release directory, so a boot variable is made pointing to the erts
    % directory.
    % NOTE the boot variable can point to either the release/erts root directory
    % or the release/erts lib directory, as long as the usage here matches the
    % usage used in the start up scripts
    case {os:type(), rlx_state:get(State, include_erts, true)} of
        {{win32, _}, false} ->
            [{"RELEASE_DIR", rlx_state:output_dir(State)}];
        {{win32, _}, true} ->
            [];
        _ ->
            [{"ERTS_LIB_DIR", code:lib_dir()}]
    end.
