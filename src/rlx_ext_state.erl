%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_ext_state).

%% API
-export([new/1]).
-export([find_release/2, find_release/3]).
-export([add_cluster/2]).
-export([default_cluster/1]).
-export([default_cluster_name/2]).
-export([include_apps/2]).
-export([rlx_state/1, rlx_state/2]).
-export([get_cluster/3]).
-export([lastest_clusters/1]).
-export([lastest_cluster/2]).

-record(state_ext, {default_cluster_name,
                    lastest_clusters = #{},
                    clusters = #{},
                    lastest_releases = #{},
                    include_apps = [],
                    rlx_state}).

new(RlxState) ->
    Releases = rlx_state:configured_releases(RlxState),
    LastestReleases =
        maps:fold(
          fun({RelName, RelVsn}, _Release, Acc) ->
                  case maps:find(RelName, Acc) of
                      {ok, RelVsn1} ->
                          case rlx_util:parsed_vsn_lte(rlx_util:parse_vsn(RelVsn1), rlx_util:parse_vsn(RelVsn)) of
                              true ->
                                  maps:put(RelName, RelVsn, Acc);
                              false ->
                                  Acc
                          end;
                      error ->
                          maps:put(RelName, RelVsn, Acc)
                  end
          end, #{}, Releases),
    #state_ext{lastest_releases = LastestReleases, rlx_state = RlxState}.

find_release(RelName, #state_ext{lastest_releases = LastestReleases, rlx_state = RlxState}) ->
    case maps:find(RelName, LastestReleases) of
        {ok, RelVsn} ->
            Release = rlx_state:get_configured_release(RlxState, RelName, RelVsn),
            {ok, Release};
        error ->
            error
    end.

find_release(RelName, RelVsn, #state_ext{rlx_state = RlxState}) ->
    Release = rlx_state:get_configured_release(RlxState, RelName, RelVsn),
    {ok, Release}.

get_cluster(#state_ext{clusters = Clusters}, ClusName, ClusVsn) ->
    maps:find({ClusName, ClusVsn}, Clusters).

rlx_state(#state_ext{rlx_state = RlxState}) ->
    RlxState.

rlx_state(#state_ext{rlx_state = RlxState} = StateExt, RlxState) ->
    StateExt#state_ext{rlx_state = RlxState}.

add_cluster(#state_ext{clusters = Clusters, lastest_clusters = LastestClusters} = RlxState, Cluster) ->
    ClusName = rlx_cluster:name(Cluster),
    ClusVsn = rlx_cluster:vsn(Cluster),
    Clusters1 = maps:put({ClusName, ClusVsn}, Cluster, Clusters),
    LastestClusters1 = rlx_ext_lib:update_lastest_vsn(ClusName, ClusVsn, LastestClusters),
    RlxState#state_ext{clusters = Clusters1, lastest_clusters = LastestClusters1}.
    
default_cluster(#state_ext{default_cluster_name = undefined, lastest_clusters = LastestClusters}) ->
    case maps:to_list(LastestClusters) of
        [{ClusName, ClusVsn}] ->
            {ok, {ClusName, ClusVsn}};
        [] ->
            {error, no_cluster_defined};
        _ ->
            {error, no_default_cluster}
    end;

default_cluster(#state_ext{default_cluster_name = ClusName} = RelxExtState) ->
    lastest_cluster(RelxExtState, ClusName).

default_cluster_name(State, DefaultClusterName) ->
    State#state_ext{default_cluster_name = DefaultClusterName}.

lastest_cluster(#state_ext{lastest_clusters = LastestClusters}, ClusName) ->
    case maps:find(ClusName, LastestClusters) of
        {ok, ClusVsn} ->
            {ok, {ClusName, ClusVsn}};
        error ->
            {error, {no_cluster_for, ClusName}}
    end.

include_apps(State, IncludeApps) ->
    State#state_ext{include_apps = IncludeApps}.

lastest_clusters(#state_ext{lastest_clusters = LastestClusters}) ->
    LastestClusters.

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
