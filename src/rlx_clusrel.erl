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
-module(rlx_clusrel).


-export([do/2, format_error/1]).

-include_lib("relx/src/relx.hrl").

%%============================================================================
%% API
%%============================================================================

%% @doc recursively dig down into the library directories specified in the state
%% looking for OTP Applications
-spec do(term(),  rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(Cluster, StateExt) ->
    State = rlx_ext_state:rlx_state(StateExt),
    ClusName = rlx_release:name(Cluster),
    OutputDir = filename:join(rlx_state:base_output_dir(State), ClusName),
    case create_rel_files(State, Cluster, OutputDir) of
        {ok, State1} ->
            sub_releases_overlay(Cluster, State1);
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
create_rel_files(State, Cluster, OutputDir) ->
    ClusRelease = rlx_cluster:solved_clus_release(Cluster),
    Variables = make_boot_script_variables(State, OutputDir),
    CodePath = rlx_util:get_code_paths(ClusRelease, OutputDir),
    write_cluster_booter_file(ClusRelease, OutputDir),

    Releases = rlx_cluster:solved_releases(Cluster),
    write_cluster_files(State, Releases, ClusRelease, OutputDir),
    lists:map(
      fun(Release) ->
              {release, _ErlInfo, _ErtsInfo, _Apps} = SubReleaseMeta = rlx_release:metadata(Release),
              write_release_files(Release, SubReleaseMeta, Variables, CodePath, OutputDir)
      end, Releases),
    {ok, State}.

%% copy booter file from rebar3_relx_ext temple
write_cluster_booter_file(Release, OutputDir) ->
    ReleaseName = rlx_release:name(Release),
    Source = filename:join([code:priv_dir(rebar3_relx_extra), "templates", "booter"]),
    Bindir = filename:join([OutputDir, "bin"]),
    case ec_file:exists(Bindir) of
        true ->
            ok = ec_file:remove(Bindir, [recursive]);
        false ->
            ok
    end,
    ok = ec_file:mkdir_p(Bindir),
    Target = filename:join([Bindir, ReleaseName]),
    ok = ec_file:copy(Source, Target).

write_cluster_files(State, SubReleases, Release, OutputDir) ->
    SubReleaseDatas = 
        lists:map(
          fun({SubReleaseName, SubReleaseVsn}) ->
                  sub_release_data(State, SubReleaseName, SubReleaseVsn)
          end, SubReleases),
    {release, _ErlInfo, _ErtsInfo, Apps} = rlx_release:metadata(Release),
    Apps1 = normalize_apps(Apps),
    ReleaseName = rlx_release:name(Release),
    ReleaseDir = rlx_util:release_output_dir(State, Release),
    ReleaseName = rlx_release:name(Release),
    ReleaseVsn = rlx_release:vsn(Release),
    Meta = {cluster, ReleaseName, ReleaseVsn, SubReleaseDatas, Apps1},
    ReleaseFile = filename:join([OutputDir, "releases", atom_to_list(ReleaseName) ++ ".clus"]),
    ReleaseFile1 = filename:join([ReleaseDir, atom_to_list(ReleaseName) ++ ".clus"]),
    ok = ec_file:write_term(ReleaseFile, Meta),
    ok = ec_file:write_term(ReleaseFile1, Meta).

sub_release_data(State, Name, Vsn) ->
    SubRelease = rlx_state:get_configured_release(State, Name, Vsn),
    Goals = rlx_release:goals(SubRelease),
    {Name, Vsn, Goals}.

sub_output_dir(Release, OutputDir) ->
    ReleaseName = rlx_release:name(Release),
    filename:join([OutputDir, "clients", ReleaseName]).

sub_release_dir(Release, OutputDir) ->
    Vsn = rlx_release:vsn(Release),
    SubOutputDir = sub_output_dir(Release, OutputDir),
    filename:join([SubOutputDir, "releases", Vsn]).

write_release_files(Release, ReleaseMeta, Variables, CodePath, OutputDir) ->
    SubOutputDir = sub_output_dir(Release, OutputDir),
    SubReleaseDir = sub_release_dir(Release, OutputDir),
    ok = ec_file:mkdir_p(SubOutputDir),
    ok = ec_file:mkdir_p(SubReleaseDir),
    ReleaseName = rlx_release:name(Release),
    ReleaseVsn = rlx_release:vsn(Release),
    RelFilename = atom_to_list(ReleaseName),
    RelLoadFileName = "load",
    {release, ErlInfo, ErtsInfo, Apps} = ReleaseMeta,
    ReleaseLoadMeta = {release, ErlInfo, ErtsInfo, apps_load(Apps)},
    copy_base_file(OutputDir, SubOutputDir),
    case write_rel_files(RelFilename, ReleaseMeta, SubReleaseDir, SubOutputDir, Variables, CodePath) of
        ok ->
            case create_RELEASES(OutputDir, RelFilename, ReleaseVsn) of
                ok ->
                    generate_start_erl_data_file(Release, SubOutputDir),
                    case write_rel_files(RelLoadFileName, ReleaseLoadMeta, SubReleaseDir, SubOutputDir, Variables, CodePath) of
                        ok ->
                            rename_and_clean_files(SubReleaseDir, RelFilename),
                            ok;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                {error, Reason} ->
                    {error, Reason}
            end; 
        {error, Reason} ->
            {error, Reason}
    end.

%% rename and remove files make files like archived project directory
rename_and_clean_files(SubReleaseDir, RelFilename) ->
    ok = ec_file:copy(filename:join(SubReleaseDir, RelFilename ++ ".boot"), filename:join(SubReleaseDir, "start.boot")),
    lists:foreach(
      fun(Filename) ->
              ok = ec_file:remove(filename:join(SubReleaseDir, Filename))
      end, ["load.rel", "load.script", RelFilename ++ ".boot", RelFilename ++ ".script"]).

create_RELEASES(OutputDir, RelFilename, ReleaseVsn) ->
    ReleaseDir =  filename:join([OutputDir, "clients", RelFilename, "releases"]),
    ReleaseFile = filename:join([ReleaseDir, ReleaseVsn, RelFilename ++ ".rel"]),
    release_handler:create_RELEASES("../..", ReleaseDir, ReleaseFile, []).

generate_start_erl_data_file(Release, OutputDir) ->
    ErtsVersion = rlx_release:erts(Release),
    ReleaseVersion = rlx_release:vsn(Release),
    Data = ErtsVersion ++ " " ++ ReleaseVersion,
    StartErl = filename:join([OutputDir, "releases", "start_erl.data"]),
    ok = file:write_file(StartErl, Data).

%% copy_file_from(Source, Target, Path) ->
%%     FromFile = filename:join([Source, Path]),
%%     ToFile = filename:join([Target, Path]),
%%     ok = ec_file:copy(FromFile, ToFile).

copy_base_file(_OutputDir, SubOutputDir) ->
    Symlink = filename:join([SubOutputDir, "lib"]),
    case ec_file:exists(Symlink) of
        true ->
            ok;
        false ->
            ok = file:make_symlink("../../lib", Symlink)
    end.
    %% copy_file_from(OutputDir, SubOutputDir, filename:join(["bin", "install_upgrade.escript"])),
    %% copy_file_from(OutputDir, SubOutputDir, filename:join(["bin", "nodetool"])).

write_rel_files(RelFilename, Meta, ReleaseDir, _OutputDir, Variables, CodePath) ->
    ReleaseFile1 = filename:join([ReleaseDir, RelFilename ++ ".rel"]),
    ok = ec_file:write_term(ReleaseFile1, Meta),
    Options = [{path, [ReleaseDir | CodePath]},
               {outdir, ReleaseDir},
               {variables, Variables},
               no_module_tests, silent],
    case systools:make_script(RelFilename, Options) of
        ok ->
            ok;
        error ->
            ?RLX_ERROR({release_script_generation_error, ReleaseFile1});
        {ok, _, []} ->
            ok;
        {ok,Module,Warnings} ->
            ?RLX_ERROR({release_script_generation_warn, Module, Warnings});
        {error,Module,Error} ->
            ?RLX_ERROR({release_script_generation_error, Module, Error})
    end.

sub_releases_overlay(Release, State) ->
    Config = rlx_release:config(Release),
    case proplists:get_value(ext, Config) of
        undefined ->
            {ok, State};
        SubReleaseNames ->
            Acc1 = 
                lists:map(
                  fun({SubReleaseName, SubReleaseVsn}) ->
                          State1 = rlx_ext_lib:sub_release_state(State, Release, SubReleaseName, SubReleaseVsn),
                          rlx_overlay:render(Release, State1)
                  end, SubReleaseNames),
            rebar3_relx_extra_lib:split_fails(
              fun(_V, StateAcc) ->
                      StateAcc
              end, State, Acc1)
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

make_boot_script_variables(State, OutputDir) ->
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
    case {os:type(), rlx_state:include_erts(State)} of
        {{win32, _}, false} ->
            [{"RELEASE_DIR", OutputDir}];
        {{win32, _}, true} ->
            [];
        _ ->
            [{"ERTS_LIB_DIR", code:lib_dir()}]
    end.

normalize_apps(Apps) ->
    lists:map(
      fun({Name, Vsn}) ->
              {Name, Vsn};
         ({Name, Vsn, _LoadType}) ->
              {Name, Vsn}
      end, Apps).

