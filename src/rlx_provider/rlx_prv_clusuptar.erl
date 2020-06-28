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
-module(rlx_prv_clusuptar).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-define(PROVIDER, clusuptar).
-define(DEPS, [clusup]).

-include_lib("relx/include/relx.hrl").

%%============================================================================
%% API
%%============================================================================

-spec init(rlx_state:t()) -> {ok, rlx_state:t()}.
init(State) ->
    State1 = rlx_state:add_provider(State, providers:create([{name, ?PROVIDER},
                                                             {module, ?MODULE},
                                                             {deps, ?DEPS}])),

    {ok, State1}.

-spec do(rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(State) ->
    {Clusname, ClusVsn} = rlx_state:default_configured_release(State),
    OutputDir = rlx_state:output_dir(State),
    FromVsn = rlx_state:upfrom(State),
    case diff_applications(OutputDir, Clusname, ClusVsn, FromVsn) of
        {ok, DiffApplications} ->
            case diff_releases(OutputDir, Clusname, ClusVsn, FromVsn) of
                {ok, Releases} ->
                    ApplicationFiles = application_files(DiffApplications, OutputDir, State),
                    ReleaseFiles = client_files(Releases, OutputDir, State),
                    make_tar(OutputDir, Clusname, ClusVsn, FromVsn, ReleaseFiles ++ ApplicationFiles, State),
                    {ok, State};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
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
                      rlx_ext_application_lib:application_files(
                        AppName, AppVsn, Paths, [{dirs, [include | maybe_src_dirs(State)]}, {output_dir, OutputDir}]),
                  ApplicationFiles ++ Acc
          end, [], Applications).

client_files(Clients, OutputDir, _State) ->
    lists:foldl(
      fun({ReleaseName, ReleaseVsn, _}, Acc) ->
              Target = filename:join(["clients", ReleaseName, "releases", ReleaseVsn]),
              File = filename:join(OutputDir, Target),
              [{Target, File}|Acc]
          end, [], Clients).

make_tar(OutputDir, Name, Vsn, FromVsn, Files, State) ->
    TarFile = filename:join(OutputDir, atom_to_list(Name) ++ "_" ++ FromVsn ++ "-" ++ Vsn ++ ".tar.gz"),
    ok = erl_tar:create(TarFile, Files, [dereference,compressed]),
    ec_cmd_log:info(rlx_state:log(State), "tarball ~s successfully created!~n", [TarFile]),
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
    SystemLibs = rlx_state:get(State, system_libs, true),
    Paths = rlx_ext_application_lib:path([{path, [filename:join([OutputDir, "lib", "*", "ebin"])]}]),
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
    case rlx_state:get(State, include_src, true) of
        false -> [];
        true -> [src]
    end.
