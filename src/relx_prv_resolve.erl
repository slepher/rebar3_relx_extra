%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 28 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(relx_prv_resolve).

%% API
-export([do/3]).

%%%===================================================================
%%% API
%%%===================================================================
do(Cluster, Apps, State) ->
    ClusRelease = relx_ext_cluster:clus_release(Cluster),
    Config = relx_ext_cluster:config(Cluster),
    {ok, State1} = lists:foldl(fun relx_ext_config:load/2, {ok, State}, Config),
    RelxState0 = relx_ext_state:rlx_state(State1),
    RelxState1 = rlx_state:available_apps(RelxState0, Apps),
    IncludeApps = relx_ext_state:include_apps(State1),
    {ok, SolvedClusRelease, RelxState2} =  solve_release(ClusRelease, IncludeApps, RelxState1),
    Releases = relx_ext_cluster:releases(Cluster),
    SolvedRelease =
        lists:map(
          fun(Release) ->
                  {ok, SolvedRelease, _RelxState2} = solve_release(Release, IncludeApps, RelxState2),
                  SolvedRelease
          end, Releases),
    Cluster1 = relx_ext_cluster:solved_clus_release(Cluster, SolvedClusRelease, SolvedRelease),
    State2 = relx_ext_state:rlx_state(State1, RelxState2),
    {ok, Cluster1, State2}.

merge_application_goals(Goals, BaseGoals) ->
    lists:foldl(fun({Key, Goal}, Acc) ->
                        lists:keystore(Key, 1, Acc, {Key, Goal})
                end, BaseGoals, rlx_release:parse_goals(Goals)).

solve_release(Release, IncludeApps, State) ->
    Goals = rlx_release:goals(Release),
    Goals1 = merge_application_goals(IncludeApps, Goals),
    Release1 = rlx_release:parsed_goals(Release, Goals1),
    rlx_resolve:solve_release(Release1, State).

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
