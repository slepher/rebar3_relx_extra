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
-define(HOOKS,  {[], []}).
%%============================================================================
%% API
%%============================================================================
-spec init(rlx_state:t()) -> {ok, rlx_state:t()}.
init(State) ->
    Provider = providers:create([{name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {deps, ?DEPS},
                                 {hooks, ?HOOKS}]),
    State1 = rlx_state:add_provider(State, Provider),
    {ok, State1}.

%% @doc recursively dig down into the library directories specified in the state
%% looking for OTP Applications
-spec do(rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(State) ->
    {RelName, RelVsn} = rlx_state:default_configured_release(State),
    Release = rlx_state:get_realized_release(State, RelName, RelVsn),
    OutputDir = rlx_state:output_dir(State),
    case create_rel_files(State, Release, OutputDir, State) of
        {ok, _} ->
            {ok, State};
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(ErrorDetail::term()) -> iolist().
format_error({unresolved_release, RelName, RelVsn}) ->
    io_lib:format("The release has not been resolved ~p-~s", [RelName, RelVsn]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).


%%%===================================================================
%%% Internal Functions
%%%===================================================================
create_rel_files(State0, Release0, OutputDir, State) ->
    ReleaseDir = rlx_util:release_output_dir(State0, Release0),
    ok = ec_file:mkdir_p(ReleaseDir),
    Variables = make_boot_script_variables(State),
    CodePath = rlx_util:get_code_paths(Release0, OutputDir),
    case sub_release_metas(Release0, State0) of
        {ok, SubReleaseMetas} ->
            Acc1 = 
                lists:map(
                  fun({SubRelease, SubReleaseMeta}) ->
                          write_release_files(SubRelease, SubReleaseMeta, State, Variables, CodePath)
                  end, SubReleaseMetas),
            rebar3_relx_extra_lib:split_fails(fun(ok, ok) -> ok end, ok, Acc1);
        {error, Reason} ->
            {error, Reason}
    end.

sub_output_dir(Release, OutputDir) ->
    ReleaseName = rlx_release:name(Release),
    filename:join([OutputDir, "sub_releases", ReleaseName]).

sub_release_dir(Release, OutputDir) ->
    Vsn = rlx_release:vsn(Release),
    SubOutputDir = sub_output_dir(Release, OutputDir),
    filename:join([SubOutputDir, "releases", Vsn]).

write_release_files(Release, ReleaseMeta, State, Variables, CodePath) ->
    OutputDir = rlx_state:output_dir(State),
    SubOutputDir = sub_output_dir(Release, OutputDir),
    SubReleaseDir = sub_release_dir(Release, OutputDir),
    ok = ec_file:mkdir_p(SubOutputDir),
    ok = ec_file:mkdir_p(SubReleaseDir),
    ok = ec_file:mkdir_p(filename:join([SubOutputDir, "bin"])),
    ReleaseName = rlx_release:name(Release),
    RelFilename = atom_to_list(ReleaseName),
    RelLoadFileName = RelFilename ++ ".load",
    {release, ErlInfo, ErtsInfo, Apps} = ReleaseMeta,
    ReleaseLoadMeta = {release, ErlInfo, ErtsInfo, apps_load(Apps)},
    Erts = rlx_release:erts(Release),
    case write_rel_files(RelFilename, ReleaseMeta, SubReleaseDir, SubOutputDir, Variables, CodePath) of
        ok ->
            case write_rel_files(RelLoadFileName, ReleaseLoadMeta, SubReleaseDir, SubOutputDir, Variables, CodePath) of
                ok ->
                    rlx_release_bin:write_bin_file(State, Release, Erts, SubOutputDir);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

write_rel_files(RelFilename, Meta, ReleaseDir, OutputDir, Variables, CodePath) ->
    ReleaseFile1 = filename:join([ReleaseDir, RelFilename ++ ".rel"]),
    ok = ec_file:write_term(ReleaseFile1, Meta),
    Bootfile = RelFilename ++ ".boot",
    ReleaseBootfile = filename:join([ReleaseDir, Bootfile]),
    BinBootfile = filename:join([OutputDir, "bin", Bootfile]),
    Options = [{path, [ReleaseDir | CodePath]},
               {outdir, ReleaseDir},
               {variables, Variables},
               no_module_tests, silent],
    case rlx_util:make_script(Options,
                              fun(CorrectedOptions) ->
                                      systools:make_script(RelFilename, CorrectedOptions)
                              end) of
        ok ->
            ok = ec_file:copy(ReleaseBootfile, BinBootfile),
            ok;
        error ->
            ?RLX_ERROR({release_script_generation_error, ReleaseFile1});
        {ok, _, []} ->
            ok = ec_file:copy(ReleaseBootfile, BinBootfile),
            ok;
        {ok,Module,Warnings} ->
            ?RLX_ERROR({release_script_generation_warn, Module, Warnings});
        {error,Module,Error} ->
            ?RLX_ERROR({release_script_generation_error, Module, Error})
    end.

sub_release_metas(Release, State) ->
    Config = rlx_release:config(Release),
    case proplists:get_value(ext, Config) of
        undefined ->
            {ok, []};
        SubReleaseNames ->
            DepGraph = create_dep_graph(State),
            Acc1 = 
                lists:map(
                  fun({SubReleaseName, SubReleaseVsn}) ->
                          case sub_release_meta(SubReleaseName, SubReleaseVsn, State, DepGraph) of
                              {ok, SubReleaseMeta} ->
                                  {ok, SubReleaseMeta};
                              {error, Reason} ->
                                  {error, {SubReleaseName, Reason}}
                          end
                  end, SubReleaseNames) ,
            rebar3_relx_extra_lib:split_fails(
              fun(V, Acc2) ->
                      [V|Acc2]
              end, [], Acc1)
    end.

sub_release_meta(SubReleaseName, SubReleaseVsn, State, DepGraph) ->
    SubRelease = rlx_state:get_configured_release(State, SubReleaseName, SubReleaseVsn),
    case realized_release(SubRelease, DepGraph, State) of
        {ok, SubRelease1} ->
            case rlx_release:metadata(SubRelease1) of
                {ok, {release, ErlInfo, ErtsInfo, Apps}} ->
                    {ok, {SubRelease1, {release, ErlInfo, ErtsInfo, Apps}}};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

apps_load(Apps) ->
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
      end, Apps).

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


create_dep_graph(State) ->
    Apps = rlx_state:available_apps(State),
    Graph0 = rlx_depsolver:new_graph(),
    lists:foldl(fun(App, Graph1) ->
                        AppName = rlx_app_info:name(App),
                        AppVsn = rlx_app_info:vsn(App),
                        Deps = rlx_app_info:active_deps(App) ++
                            rlx_app_info:library_deps(App),
                        rlx_depsolver:add_package_version(Graph1,
                                                          AppName,
                                                          AppVsn,
                                                          Deps)
                end, Graph0, Apps).


realized_release(Release, DepGraph, State) ->
    ReleaseName = rlx_release:name(Release),
    Goals = rlx_release:goals(Release),
    case Goals of
        [] ->
            {error, {ReleaseName, no_goals_specified}};
        _ ->
            case rlx_depsolver:solve(DepGraph, Goals) of
                {ok, Pkgs} ->
                    rlx_release:realize(Release, Pkgs, rlx_state:available_apps(State));
                {error, Error} ->
                    {error, {ReleaseName, failed_solve, Error}}
            end
    end.
