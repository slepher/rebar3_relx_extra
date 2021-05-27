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

add_cluster(#state_ext{clusters = Clusters} = RlxState, Cluster) ->
    ClusName = rlx_cluster:name(Cluster),
    ClusVsn = rlx_cluster:vsn(Cluster),
    Clusters1 = maps:put({ClusName, ClusVsn}, Cluster, Clusters),
    RlxState#state_ext{clusters = Clusters1}.
    
default_cluster(#state_ext{default_cluster_name = ClusName, lastest_clusters = LatestClusters}) ->
    ClusVsn = maps:get(ClusName, LatestClusters),
    {ClusName, ClusVsn}.

default_cluster_name(State, DefaultClusterName) ->
    State#state_ext{default_cluster_name = DefaultClusterName}.

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
