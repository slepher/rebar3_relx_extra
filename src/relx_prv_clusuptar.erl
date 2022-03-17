%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 80 -*-
%%% Copyright 2014 Erlware, LLC. All Rights Reserved.
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
%%% @author Tristan Sloughter <t@crashfast.com>
%%% @copyright (C) 2014 Erlware, LLC.
%%%
%%% @doc Given a complete built release this provider assembles that release
%%% into a release directory.
-module(relx_prv_clusuptar).

-include_lib("providers/include/providers.hrl").

-export([do/3, format_error/1]).

%%============================================================================
%% API
%%============================================================================
do(Cluster, UpFromVsn, State) ->
    ClusName = relx_ext_cluster:name(Cluster),
    ClusVsn = relx_ext_cluster:vsn(Cluster),
    RelxState = relx_ext_state:rlx_state(State),
    Dir = rlx_state:base_output_dir(RelxState),
    OutputDir = filename:join(Dir, ClusName),
    case diff_applications(OutputDir, ClusName, ClusVsn, UpFromVsn) of
        {ok, DiffApplications} ->
            case diff_releases(OutputDir, ClusName, ClusVsn, UpFromVsn) of
                {ok, Releases} ->
                    ExtraReleases = extra_releases(ClusName, ClusVsn, OutputDir),
                    ApplicationFiles = application_files(DiffApplications, OutputDir, RelxState),
                    ReleaseFiles = client_files(Cluster, Releases, OutputDir, ExtraReleases, State),
                    ClusupBasename = atom_to_list(ClusName) ++ ".clusup",
                    ClusBasename = atom_to_list(ClusName) ++ ".clus",
                    ClusFiles = [{filename:join(["releases", ClusVsn, ClusBasename]),
                                  filename:join([OutputDir, "releases", ClusVsn, ClusBasename])},
                                 {filename:join(["releases", ClusVsn, ClusupBasename]),
                                  filename:join([OutputDir, "releases", ClusVsn, ClusupBasename])}],
                    make_tar(OutputDir, ClusName, ClusVsn, UpFromVsn, ReleaseFiles ++ ApplicationFiles ++ ClusFiles, RelxState),
                    {ok, State};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}

    end.

extra_releases(ClusName, ClusVsn, OutputDir) ->
    ClusupBasename = atom_to_list(ClusName) ++ ".clusup",
    Clusup = filename:join([OutputDir, "releases", ClusVsn, ClusupBasename]),
    case file:consult(Clusup) of
        {ok, [{clusup, _ClusterName, _ClusterVsn, _UpFromClusterVsn, ReleasesChanged, _AppsChanged, _Extra}]} ->
            lists:foldl(
              fun({add, Name, _Vsn}, Acc) ->
                      [Name|Acc];
                 (_, Acc) ->
                      Acc
              end, [], ReleasesChanged);
        Other ->
            io:format("get extra releases failed ~p~n", [Other]),
            []
    end.

diff_applications(OutputDir, Clusname, ClusVsn, FromVsn) ->
    ClusFilename = atom_to_list(Clusname),
    Relfile = filename:join([OutputDir, "releases", ClusVsn, ClusFilename ++ ".clus"]),
    FromRelfile = filename:join([OutputDir, "releases", FromVsn, ClusFilename ++ ".clus"]),
    case get_apps(Relfile) of
        {ok, RelApps} ->
            case get_apps(FromRelfile) of
                {ok, FromApps} ->
                    {ok, RelApps -- FromApps};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

diff_releases(OutputDir, Clusname, ClusVsn, FromVsn) ->
    ClusFilename = atom_to_list(Clusname),
    Relfile = filename:join([OutputDir, "releases", ClusVsn, ClusFilename ++ ".clus"]),
    FromRelfile = filename:join([OutputDir, "releases", FromVsn, ClusFilename ++ ".clus"]),
    case get_releases(Relfile) of
        {ok, RelApps} ->
            case get_releases(FromRelfile) of
                {ok, FromApps} ->
                    {ok, RelApps -- FromApps};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

application_files(Applications, OutputDir, State) ->
    Paths = paths(State, OutputDir),
    lists:foldl(
      fun({AppName, AppVsn}, Acc) ->
              {ok, ApplicationFiles} = 
                      relx_ext_lib:application_files(
                        AppName, AppVsn, Paths, [{dirs, [include | maybe_src_dirs(State)]}, {output_dir, OutputDir}]),
                  ApplicationFiles ++ Acc
          end, [], Applications).

client_files(Cluster, Clients, OutputDir, ExtraReleases, StateExt) ->
    lists:foldl(
      fun({ReleaseName, ReleaseVsn, _}, Acc) ->
              case lists:member(ReleaseName, ExtraReleases) of
                  false ->
                      Target = filename:join(["clients", ReleaseName, "releases", ReleaseVsn]),
                      add_target(Target, OutputDir, Acc);
                  true ->
                      State = relx_ext_state:rlx_state(StateExt),
                      Releases = relx_ext_cluster:solved_releases(Cluster),
                      case lists:keyfind(ReleaseName, 2, Releases) of
                          false ->
                              erlang:error(?PRV_ERROR({invalid_sub_release, ReleaseName}));
                          SubRelease ->
                              relx_prv_clustar:sub_release_files(SubRelease, State, OutputDir)
                      end
              end
          end, [], Clients).

add_target(Target, OutputDir, Acc) ->
    [{Target, filename:join(OutputDir, Target)}|Acc].

make_tar(OutputDir, Name, Vsn, FromVsn, Files, State) ->
    TarFile = filename:join(OutputDir, atom_to_list(Name) ++ "_" ++ FromVsn ++ "-" ++ Vsn ++ ".tar.gz"),
    ok = erl_tar:create(TarFile, Files, [dereference,compressed]),
    rebar_api:info("tarball ~s successfully created!~n", [TarFile]),
    {ok, State}.

get_releases(Relfile) ->
    case file:consult(Relfile) of
        {ok, [{cluster, _Clusname, _ClusVsn, Releases, _Apps}]} when is_list(Releases) ->
            {ok, Releases};
        {ok, _} ->
            {error, {invalid_file_content, Relfile}};
        {error, Reason} ->
            {error, Reason}
    end.

get_apps(Relfile) ->
    case file:consult(Relfile) of
        {ok, [{cluster, _Clusname, _ClusVsn, _Releases, Apps}]} when is_list(Apps) ->
            {ok, Apps};
        {ok, _} ->
            {error, {invalid_file_content, Relfile}};
        {error, Reason} ->
            {error, Reason}
    end.

paths(State, OutputDir) ->
    SystemLibs = rlx_state:system_libs(State),
    Paths = relx_ext_lib:path([{path, [filename:join([OutputDir, "lib", "*", "ebin"])]}]),
        case SystemLibs of
            true ->
                Paths;
            false ->
                lists:filter(
                  fun(Path) ->
                          not lists:prefix(code:lib_dir(), Path)
                  end, Paths)
        end.

format_error({tar_unknown_generation_error, Module, Vsn}) ->
    io_lib:format("Tarball generation error of ~s ~s",
                  [Module, Vsn]);
format_error({tar_generation_warn, Module, Warnings}) ->
    io_lib:format("Tarball generation warnings for ~p : ~p",
                  [Module, Warnings]);
format_error({tar_generation_error, Module, Errors}) ->
    io_lib:format("Tarball generation error for ~p reason ~p",
                  [Module, Errors]);
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

maybe_src_dirs(State) ->
    case include_src_or_default(State) of
        false -> [];
        true -> [src]
    end.

%% when running `tar' the default is to exclude src
include_src_or_default(State) ->
    case rlx_state:include_src(State) of
        undefined ->
            false;
        IncludeSrc ->
            IncludeSrc
    end.
