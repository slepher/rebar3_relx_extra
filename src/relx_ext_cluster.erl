%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(relx_ext_cluster).

%% API
-export([new/2, name/1, vsn/1]).
-export([add_release/2]).
-export([config/1, config/2]).
-export([releases/1, solved_releases/1, clus_release/1]).
-export([solved_clus_release/1, solved_clus_release/3]).

-record(cluster, {name, vsn, releases = [], solved_releases = [], config = [], clus_release, solved_clus_release}).

%%%===================================================================
%%% API
%%%===================================================================
new(Name, Vsn) ->
    Release = rlx_release:new(Name, Vsn),
    Release1 = rlx_release:goals(Release, []),
    #cluster{name = Name, vsn = Vsn, clus_release = Release1}.

name(#cluster{name = Name}) ->
    Name.

vsn(#cluster{vsn = Vsn}) ->
    Vsn.

config(#cluster{config = Config}) ->
    Config.
    
config(#cluster{} = Cluster, Config) ->
    Cluster#cluster{config = Config}.

add_release(#cluster{clus_release = ClusRelease, releases = Releases} = Cluster, Release) ->
    ClusParsedGoals = rlx_release:goals(ClusRelease),
    ClusParsedGoals1 = ordsets:union(ClusParsedGoals, ordsets:from_list(rlx_release:goals(Release))),
    ClusRelease1 = rlx_release:parsed_goals(ClusRelease, ClusParsedGoals1),
    Releases1 = ordsets:add_element(Release, Releases),
    Cluster#cluster{clus_release = ClusRelease1, releases = Releases1}.

releases(#cluster{releases = Releases}) ->
    Releases.

solved_releases(#cluster{solved_releases = SolvedReleases}) ->
    SolvedReleases.

clus_release(#cluster{clus_release = ClusRelease}) ->
    ClusRelease.

solved_clus_release(#cluster{solved_clus_release = SolvedClusRelease}) ->
    SolvedClusRelease.

solved_clus_release(#cluster{} = State, SolvedClusRelease, SolvedReleases) ->
    State#cluster{solved_clus_release = SolvedClusRelease, solved_releases = SolvedReleases}.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
