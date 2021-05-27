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
-module(rlx_clusup).

-export([do/4, format_error/1]).

-include_lib("relx/src/relx.hrl").
-include_lib("relx/src/rlx_log.hrl").

%%============================================================================
%% API
%%============================================================================


-spec do(atom(), string(), string(), rlx_state:t()) -> {ok, rlx_state:t()} | relx:error().
do(ClusterName, ClusterVsn, FromVsn, State) ->
    Dir = rlx_state:base_output_dir(State),
    case resolve_cluster(find_cluster_file(ClusterName, ClusterVsn, Dir)) of
        {ok, {Releases, Apps}} ->
            case resolve_cluster(find_cluster_file(ClusterName, FromVsn, Dir)) of
                {ok, {UpFromReleases, UpFromApps}} ->
                    make_upfrom_cluster_script(
                      ClusterName, ClusterVsn, FromVsn, Releases, Apps, UpFromReleases, UpFromApps, State),
                    make_upfrom_release_scripts(ClusterName, Releases, UpFromReleases, State);
                {error, _Reason} ->
                    ?RLX_ERROR({no_upfrom_release_found, ClusterVsn})
            end;
        {error, _Reason} ->
            ?RLX_ERROR({no_release_found, ClusterVsn})
    end.

format_error({relup_generation_error, CurrentName, UpFromName}) ->
    io_lib:format("Unknown internal release error generating the relup from ~s to ~s",
                  [UpFromName, CurrentName]);
format_error({relup_generation_warning, Module, Warnings}) ->
    ["Warnings generating relup \s",
     rlx_util:indent(2), Module:format_warning(Warnings)];
format_error({no_upfrom_release_found, undefined}) ->
    io_lib:format("No earlier release for relup found", []);
format_error({no_upfrom_release_found, Vsn}) ->
    io_lib:format("Upfrom release version (~s) for relup not found", [Vsn]);
format_error({relup_script_generation_error,
              {relup_script_generation_error, systools_relup,
               {missing_sasl, _}}}) ->
    "Unfortunately, due to requirements in systools, you need to have the sasl application "
        "in both the current release and the release to upgrade from.";
format_error({relup_script_generation_warn, systools_relup,
               [{erts_vsn_changed, _},
                {erts_vsn_changed, _}]}) ->
    "It has been detected that the ERTS version changed while generating the relup between versions, "
    "please be aware that an instruction that will automatically restart the VM will be inserted in "
    "this case";
format_error({relup_script_generation_warn, Module, Warnings}) ->
    ["Warnings generating relup \n",
     rlx_util:indent(2), Module:format_warning(Warnings)];
format_error({relup_script_generation_error, Module, Errors}) ->
    ["Errors generating relup \n",
     rlx_util:indent(2), Module:format_error(Errors)];
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

resolve_cluster(File) ->
    case file:consult(File) of
        {ok, [{cluster, _ClusterName, _ClusterVsn, Releases, Applications}]} ->
            {ok, {Releases, Applications}};
        {error, Reason} ->
            {error, Reason}
    end.

find_cluster_file(Name, Vsn, Dir) when is_atom(Name) ,
                                       is_list(Vsn) ->
    RelFile = filename:join([Dir, atom_to_list(Name), "releases", Vsn, atom_to_list(Name) ++ ".clus"]),
    case filelib:is_regular(RelFile) of
        true ->
            RelFile;
        _ ->
            erlang:error(?RLX_ERROR({clusfile_not_found, {Name, Vsn}}))
    end;
find_cluster_file(Name, Vsn, _) ->
    erlang:error(?RLX_ERROR({bad_rel_tuple, {Name, Vsn}})).

make_upfrom_cluster_script(ClusterName, ClusterVsn, UpFromClusterVsn, Releases, Apps, UpFromReleases, UpFromApps, State) ->
    Releases1 = lists:map(fun({Name, Vsn, _Apps}) -> {Name, Vsn} end, Releases),
    UpFromReleases1 = lists:map(fun({Name, Vsn, _Apps}) -> {Name, Vsn} end, UpFromReleases),
    ReleasesChanged = changed(Releases1, UpFromReleases1),
    AppsChanged = changed(Apps, UpFromApps),
    Meta = {clusup, ClusterName, ClusterVsn, UpFromClusterVsn, ReleasesChanged, AppsChanged, []},
    write_clusup_file(State, ClusterName, ClusterVsn, Meta).
    
changed(Metas, MetasFrom) ->
    {Changes, Adds, Dels} = 
        lists:foldl(
          fun({Name, Vsn}, {ChangesAcc, AddsAcc, DelsAcc}) ->
                  case proplists:get_value(Name, MetasFrom) of
                      undefined ->
                          AddsAcc1 = [{add, Name, Vsn}|AddsAcc],
                          {ChangesAcc, AddsAcc1, DelsAcc};
                      Vsn ->
                          DelsAcc1 = proplists:delete(Name, DelsAcc),
                          {ChangesAcc, AddsAcc, DelsAcc1};
                      Vsn1 ->
                          ChangesAcc1 = [{change, Name, Vsn, Vsn1}|ChangesAcc],
                          DelsAcc1 = proplists:delete(Name, DelsAcc),
                          {ChangesAcc1, AddsAcc, DelsAcc1}
                  end
          end, {[], [], MetasFrom}, Metas),
    Dels1 = lists:map(fun({Name, Vsn}) -> {del, Name, Vsn} end, Dels),
    Adds ++ Dels1 ++ Changes.

make_upfrom_release_scripts(ClusterName, Releases, UpFromReleases, State) ->
    lists:foldl(
      fun({RelName, RelVsn, _RelApps}, {ok, StateAcc}) ->
              case lists:keyfind(RelName, 1, UpFromReleases) of
                  undefined ->
                      {ok, State};
                  {RelName, UpFromRelVsn, _} ->
                      case RelVsn == UpFromRelVsn of
                          true ->
                              {ok, State};
                          false ->
                              make_upfrom_script(ClusterName, RelName, RelVsn, UpFromRelVsn, StateAcc)
                      end
              end;
         (_, {error, Reason}) ->
              {error, Reason}
      end, {ok, State}, Releases).


make_upfrom_script(ClusterName, RelName, RelVsn, UpFromVsn, State) ->
    OutputDir = rlx_state:base_output_dir(State),
    ClientDir = filename:join([OutputDir, ClusterName, "clients"]),
    WarningsAsErrors = rlx_state:warnings_as_errors(State),
    Options = [no_warn_sasl,
               {outdir, ClientDir},
               {path, [filename:join([ClientDir, "*", "lib", "*", "ebin"])]},
               {silent, true} | case WarningsAsErrors of
                                    true -> [warnings_as_errors];
                                    false -> []
                                end],
               %% the following block can be uncommented
               %% when systools:make_relup/4 returns
               %% {error,Module,Errors} instead of error
               %% when taking the warnings_as_errors option
               %% ++
               %% case WarningsAsErrors of
               %%     true -> [warnings_as_errors];
               %%     false -> []
              % end,
    CurrentRel = strip_dot_rel(find_rel_file(RelName, RelVsn, ClientDir)),
    UpFromRel =  strip_dot_rel(find_rel_file(RelName, UpFromVsn, ClientDir)),
    %% ?log_debug("systools:make_relup(~p, ~p, ~p, ~p)", [CurrentRel, UpFromRel, UpFromRel, Options]),
    case systools:make_relup(CurrentRel, [UpFromRel], [UpFromRel], Options) of
        ok ->
            ?log_info("relup from ~s to ~s successfully created!~n", [UpFromRel, CurrentRel]),
            {ok, State};
        error ->
            erlang:error(?RLX_ERROR({relup_generation_error, CurrentRel, UpFromRel}));
        {ok, RelUp, _, []} ->
            write_relup_file(RelName, RelVsn, RelUp, ClientDir),
            ?log_info("relup ~p from ~s to ~s successfully created!~n", [RelName, UpFromVsn, RelVsn]),
            {ok, State};
        {ok, RelUp, Module, Warnings} ->
            case WarningsAsErrors of
                true ->
                    %% since we don't pass the warnings_as_errors option
                    %% the relup file gets generated anyway, we need to delete
                    %% it
                    file:delete(filename:join([OutputDir, "relup"])),
                    ?RLX_ERROR({relup_script_generation_warn, Module, Warnings});
                false ->
                    write_relup_file(RelName, RelVsn, RelUp, ClientDir),
                    ?log_warn(format_error({relup_script_generation_warn, Module, Warnings})),
                    {ok, State}
            end;
        {error,Module,Errors} ->
            ?RLX_ERROR({relup_script_generation_error, Module, Errors})
    end.

write_clusup_file(State, ClusterName, ClusterVsn, Clusup) ->
    ClusupBasename = atom_to_list(ClusterName) ++ ".clusup",
    BaseOutputDir = rlx_state:base_output_dir(State),
    OutputDir = filename:join([BaseOutputDir, ClusterName]),
    ClusupFile1 = filename:join([OutputDir, "releases", ClusterVsn, ClusupBasename]),
    ClusupFile2 = filename:join([OutputDir, "releases", ClusupBasename]),
    ok = ec_file:write_term(ClusupFile1, Clusup),
    ok = ec_file:write_term(ClusupFile2, Clusup).

write_relup_file(ReleaseName, ReleaseVsn, Relup, ClientDir) ->
    RelupFile = filename:join([ClientDir, ReleaseName, "releases", ReleaseVsn, "relup"]),
    ok = ec_file:write_term(RelupFile, Relup).

%% return path to rel file without the .rel extension as a string (not binary)
strip_dot_rel(Name) ->
    rlx_util:to_string(filename:join(filename:dirname(Name),
                                     filename:basename(Name, ".rel"))).

find_rel_file(Name, Vsn, Dir) when is_atom(Name) ,
                                   is_list(Vsn) ->
    RelFile = filename:join([Dir, atom_to_list(Name), "releases", Vsn, atom_to_list(Name) ++ ".rel"]),
    case filelib:is_regular(RelFile) of
        true ->
            RelFile;
        _ ->
            erlang:error(?RLX_ERROR({relfile_not_found, {Name, Vsn}}))
    end;
find_rel_file(Name, Vsn, _) ->
    erlang:error(?RLX_ERROR({bad_rel_tuple, {Name, Vsn}})).
