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
-module(rlx_prv_clusup).

-behaviour(provider).

-export([init/1,
         do/1,
         format_error/1]).

-include_lib("relx/include/relx.hrl").

-define(PROVIDER, clusup).
-define(DEPS, []).
-define(HOOKS,  {[], []}).
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
do(State0) ->
    {RelName, RelVsn} = rlx_state:default_configured_release(State0),
    OutputDir = erlang:iolist_to_binary(filename:join([rlx_state:base_output_dir(State0), atom_to_list(RelName), "lib"])),
    LibDirs = lists:flatten([add_system_lib_dir(State0), add_environment_lib_dir(State0), OutputDir]),
    case rlx_app_discovery:do(State0, LibDirs) of
        {ok, AppMeta} ->
            State = rlx_state:available_apps(State0, AppMeta),
            case merge_results(discover_clusters(RelName, State)) of
                {ok, Clusters} ->
                    make_clusup(RelName, RelVsn, Clusters, State);
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
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
     rlx_util:indent(2), Module:format_error(Errors)].


-spec add_system_lib_dir(rlx_state:t()) -> [file:name()].
add_system_lib_dir(State) ->
    ExcludeSystem = rlx_state:get(State, discover_exclude_system, false),
    case rlx_state:get(State, system_libs, true) of
        Atom when is_atom(Atom) ->
            case ExcludeSystem of
                true ->
                    [];
                false ->
                    erlang:iolist_to_binary(code:lib_dir())
            end;
        SystemLibs ->
            erlang:iolist_to_binary(SystemLibs)
    end.

add_environment_lib_dir(_State) ->
    case os:getenv("ERL_LIBS") of
        false -> [];
        Libs -> [erlang:iolist_to_binary(L) || L <- rlx_string:lexemes(Libs, ":")]
    end.

discover_clusters(RelName, State) ->
    Output = rlx_state:base_output_dir(State),
    RelDir = filename:join([Output, RelName, "releases"]),
    case ec_file:exists(RelDir) of
        true ->
            rlx_dscv_util:do(
               fun(File, file) ->
                       case filename:extension(File) of
                           ".clus" ->
                               resolve_cluster(File);
                           _ ->
                               {noresult, false}
                       end;
                  (_Directory, directory) ->
                       {noresult, true}
               end, [RelDir]);
        false ->
            []
    end.

merge_results(Clusters) ->
    Errors = [case El of
                  {error, Ret} -> Ret;
                  _ -> El
              end
              || El <- Clusters,
                 case El of
                     {error, _} ->
                         true;
                     _ ->
                         false
                 end],
    case Errors of
        [] ->
            Clusters1 = [Cluster || {ok, Cluster} <- Clusters],
            {ok, Clusters1};
        _ ->
            ?RLX_ERROR(Errors)
    end.

resolve_cluster(File) ->
    case file:consult(File) of
        {ok, [{cluster, ClusterName, ClusterVsn, Releases, Applications}]} ->
            {ok, {{ClusterName, ClusterVsn}, {Releases, Applications}}};
        {error, Reason} ->
            {error, Reason}
    end.

make_clusup(ClusterName, ClusterVsn, Clusters, State) ->
    case get_releases(ClusterName, ClusterVsn, Clusters) of
        undefined ->
            ?RLX_ERROR({no_release_found, ClusterVsn});
        {Releases, Apps} ->
            UpFrom = rlx_state:upfrom(State),
            UpFrom1 =
                case UpFrom of
                    undefined ->
                        get_last_release(ClusterName, ClusterVsn, Clusters);
                    Vsn ->
                        get_releases(ClusterName, Vsn, Clusters)
                end,
            case UpFrom1 of
                undefined ->
                    ?RLX_ERROR({no_upfrom_release_found, ClusterVsn});
                {UpFromReleases, UpFromApps} ->
                    make_upfrom_cluster_script(ClusterName, ClusterVsn, Releases, Apps, UpFromReleases, UpFromApps, State),
                    make_upfrom_release_scripts(ClusterName, Releases, UpFromReleases, State)
            end
    end.

get_last_release(ClusterName, ClusterVsn, Clusters) ->
    case get_last_release_vsn(ClusterName, ClusterVsn, Clusters) of
        {ok, ClusterVsn1} ->
            get_releases(ClusterName, ClusterVsn1, Clusters);
        {error, Reason} ->
            {error, Reason}
    end.

get_last_release_vsn(ClusterName, ClusterVsn, Clusters) ->
    ClusterVsns = [ClusterVsn1 || {{ClusterName1, ClusterVsn1}, _} <- Clusters, ClusterName1 == ClusterName],
    case lists:filter(
           fun(ClusterVsn1) ->
                   ec_semver:lt(ClusterVsn1, ClusterVsn)
           end, ClusterVsns) of
        [] ->
            {error, no_last_release};
        [ClusterVsn1|ClusterVsns1] ->
            {ok, 
             lists:foldl(
               fun(ClusterVsn2, Acc) -> 
                       case ec_semver:gt(ClusterVsn2, Acc) of
                           true ->
                               ClusterVsn2;
                           false ->
                               Acc
                       end
               end, ClusterVsn1, ClusterVsns1)}
    end.

get_releases(ClusterName, ClusterVsn, Clusters) ->
    proplists:get_value({ClusterName, ClusterVsn}, Clusters).

make_upfrom_cluster_script(ClusterName, ClusterVsn, Releases, Apps, UpFromReleases, UpFromApps, State) ->
    Releases1 = lists:map(fun({Name, Vsn, _Apps}) -> {Name, Vsn} end, Releases),
    UpFromReleases1 = lists:map(fun({Name, Vsn, _Apps}) -> {Name, Vsn} end, UpFromReleases),
    ReleasesChanged = changed(Releases1, UpFromReleases1),
    AppsChanged = changed(Apps, UpFromApps),
    Meta = {clusup, ClusterName, ReleasesChanged, AppsChanged},
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
              case proplists:get_value(RelName, UpFromReleases) of
                  undefined ->
                      {ok, State};
                  UpFromRelVsn ->
                      case RelVsn == UpFromRelVsn of
                          true ->
                              {ok, State};
                          false ->
                              case rel_discover(ClusterName, RelName, RelVsn, State) of
                                  {ok, Release} ->
                                      case rel_discover(ClusterName, RelName, UpFromRelVsn, State) of
                                          {ok, UpFromRelease} ->
                                              make_upfrom_script(StateAcc, Release, UpFromRelease);
                                          {error, Reason} ->
                                      {error, Reason}
                                      end;
                                  {error, Reason} ->
                                      {error, Reason}
                              end
                      end
              end;
         (_, {error, Reason}) ->
              {error, Reason}
      end, {ok, State}, Releases).

rel_discover(ClusterName, RelName, RelVsn, State) ->
    Output = rlx_state:base_output_dir(State),
    FileName = filename:join([Output, ClusterName, "clients", RelName, "releases", RelVsn, atom_to_list(RelName) ++ ".rel"]),
    AppMeta = rlx_state:available_apps(State),
    resolve_release(FileName, AppMeta).

resolve_release(RelFile, AppMeta) ->
    case file:consult(RelFile) of
        {ok, [{release, {RelName, RelVsn},
               {erts, ErtsVsn},
               Apps}]} ->
            build_release(RelFile, RelName, RelVsn, ErtsVsn, Apps, AppMeta);
        {ok, InvalidRelease} ->
            ?RLX_ERROR({invalid_release_information, InvalidRelease});
        {error, Reason} ->
            ?RLX_ERROR({unable_to_read, RelFile, Reason})
    end.

build_release(RelFile, RelName, RelVsn, ErtsVsn, Apps, AppMeta) ->
    Release = rlx_release:erts(rlx_release:new(RelName, RelVsn, RelFile), ErtsVsn),
    resolve_apps(Apps, AppMeta, Release, []).

resolve_apps([], _AppMeta, Release, Acc) ->
    {ok, rlx_release:application_details(Release, Acc)};
resolve_apps([AppInfo | Apps], AppMeta, Release, Acc) ->
    AppName = erlang:element(1, AppInfo),
    AppVsn = ec_semver:parse(erlang:element(2, AppInfo)),
    case find_app(AppName, AppVsn, AppMeta) of
        Error = {error, _} ->
            Error;
        ResolvedApp ->
            resolve_apps(Apps, AppMeta, Release, [ResolvedApp | Acc])
    end.

find_app(AppName, AppVsn, AppMeta) ->
    case ec_lists:find(fun(App) ->
                               NAppName = rlx_app_info:name(App),
                               NAppVsn = rlx_app_info:vsn(App),
                               AppName == NAppName andalso
                                   AppVsn == NAppVsn
                       end, AppMeta) of
        {ok, Head} ->
            Head;
        error ->
            ?RLX_ERROR({could_not_find, {AppName, AppVsn}})
    end.

make_upfrom_script(State, Release, UpFrom) ->
    OutputDir = rlx_state:output_dir(State),
    WarningsAsErrors = rlx_state:warnings_as_errors(State),
    Options = [{outdir, OutputDir},
               {path, rlx_util:get_code_paths(Release, OutputDir) ++
                   rlx_util:get_code_paths(UpFrom, OutputDir)},
               silent],
               %% the following block can be uncommented
               %% when systools:make_relup/4 returns
               %% {error,Module,Errors} instead of error
               %% when taking the warnings_as_errors option
               %% ++
               %% case WarningsAsErrors of
               %%     true -> [warnings_as_errors];
               %%     false -> []
              % end,
    CurrentRel = strip_rel(rlx_release:relfile(Release)),
    UpFromRel = strip_rel(rlx_release:relfile(UpFrom)),
    ec_cmd_log:debug(rlx_state:log(State),
                  "systools:make_relup(~p, ~p, ~p, ~p)",
                  [CurrentRel, UpFromRel, UpFromRel, Options]),
    case rlx_util:make_script(Options,
                     fun(CorrectOptions) ->
                             systools:make_relup(CurrentRel, [UpFromRel], [UpFromRel], CorrectOptions)
                     end) of
        ok ->
            ec_cmd_log:info(rlx_state:log(State),
                          "relup from ~s to ~s successfully created!",
                          [UpFromRel, CurrentRel]),
            {ok, State};
        error ->
            ?RLX_ERROR({relup_generation_error, CurrentRel, UpFromRel});
        {ok, RelUp, _, []} ->
            write_relup_file(State, Release, RelUp),
            ec_cmd_log:info(rlx_state:log(State),
                            "relup successfully created!"),
            {ok, State};
        {ok, RelUp, Module,Warnings} ->
            case WarningsAsErrors of
                true ->
                    %% since we don't pass the warnings_as_errors option
                    %% the relup file gets generated anyway, we need to delete
                    %% it
                    file:delete(filename:join([OutputDir, "relup"])),
                    ?RLX_ERROR({relup_script_generation_warn, Module, Warnings});
                false ->
                    write_relup_file(State, Release, RelUp),
                    ec_cmd_log:warn(rlx_state:log(State),
                            format_error({relup_script_generation_warn, Module, Warnings})),
                    {ok, State}
            end;
        {error,Module,Errors} ->
            ?RLX_ERROR({relup_script_generation_error, Module, Errors})
    end.

write_clusup_file(State, _ClusterName, ClusterVsn, Clusup) ->
    OutputDir = rlx_state:output_dir(State),
    ClusupFile1 = filename:join([OutputDir, "releases", ClusterVsn, "clusup"]),
    ClusupFile2 = filename:join([OutputDir, "clusup"]),
    ok = ec_file:write_term(ClusupFile1, Clusup),
    ok = ec_file:write_term(ClusupFile2, Clusup).

write_relup_file(State, Release, Relup) ->
    OutputDir = rlx_state:output_dir(State),
    ReleaseName = rlx_release:name(Release),
    ReleaseVsn = rlx_release:vsn(Release),
    RelupFile = filename:join([OutputDir, "clients", ReleaseName, "releases", ReleaseVsn, "relup"]),
    ok = ec_file:write_term(RelupFile, Relup).

strip_rel(Name) ->
    rlx_util:to_string(filename:join(filename:dirname(Name),
                                     filename:basename(Name, ".rel"))).
