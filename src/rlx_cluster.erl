%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_cluster).

%% API
-export([new/2, name/1, vsn/1]).
-export([add_release/2]).
-export([config/2]).

-record(cluster, {name, vsn, releases = [], config = [], rlx_release}).

%%%===================================================================
%%% API
%%%===================================================================
new(Name, Vsn) ->
    Release = rlx_release:new(Name, Vsn),
    #cluster{name = Name, vsn = Vsn, rlx_release = Release}.

name(#cluster{name = Name}) ->
    Name.

vsn(#cluster{vsn = Vsn}) ->
    Vsn.

config(#cluster{rlx_release = Release} = Cluster, Config) ->
    Goals = proplists:get_value(incl_apps, Config, []),
    Release1 = rlx_release:goals(Release, Goals),
    Cluster#cluster{config = Config, rlx_release = Release1}.

add_release(#cluster{rlx_release = ClusRelease, releases = Releases} = Cluster, Release) ->
    ClusParsedGoals = rlx_release:goals(ClusRelease),
    ParsedGoals = rlx_release:goals(Release),
    ClusParsedGoals1 =
        lists:foldl(
          fun({Key, Goal}, Acc) ->
                  lists:keystore(Key, 1, Acc, {Key, Goal})
          end, ClusParsedGoals, ParsedGoals),
    ClusRelease1 = rlx_release:parsed_goals(ClusRelease, ClusParsedGoals1),
    Releases1 = ordsets:add_element(Release, Releases),
    Cluster#cluster{rlx_release = ClusRelease1, releases = Releases1}.


%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
