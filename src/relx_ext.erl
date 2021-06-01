%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 25 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(relx_ext).

-include("relx_ext.hrl").

%% API
-export([build_clusrel/3, build_clustar/3]).

-export([build_clusup/6, build_clusuptar/4]).

-export([format_error/1]).
%%%===================================================================
%%% API
%%%===================================================================
build_clusrel(Cluster, Apps, State) ->
    {ok, RealizedCluster, State1} =
        relx_prv_resolve:do(Cluster, Apps, State),
    {ok, State2} = relx_prv_assemble:do(RealizedCluster, State1),
    relx_prv_clusrel:do(RealizedCluster, State2).

build_clustar(Cluster, Apps, State) ->
    {ok, RealizedCluster, State1} =
        relx_prv_resolve:do(Cluster, Apps, State),
    relx_prv_clustar:do(RealizedCluster, State1).

build_clusup(ClusterName, ClusterVsn, UpFromVsn, Apps, Opts, RelxState) ->
    {ok, RelxState1} = relx_prv_appup:do(ClusterName, ClusterVsn, UpFromVsn, Apps, Opts, RelxState),
    relx_prv_clusup:do(ClusterName, ClusterVsn, UpFromVsn, RelxState1),
    RelxState.

build_clusuptar(ClusterName, ClusterVsn, UpFromVsn, RelxState) ->
    relx_prv_clusuptar:do(ClusterName, ClusterVsn, UpFromVsn, RelxState),
    RelxState.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
-spec format_error(Reason::term()) -> string().
format_error({unrecognized_release, Release}) ->
    io_lib:format("Could not understand release argument ~p~n", [Release]);
format_error({error, {relx, Reason}}) ->
    format_error(Reason);
format_error({no_release_name, Vsn}) ->
    io_lib:format("A target release version was specified (~s) but no name", [Vsn]);
format_error({invalid_release_info, Info}) ->
    io_lib:format("Target release information is in an invalid format ~p", [Info]);
format_error({multiple_release_names, _, _}) ->
    "Must specify the name of the release to build when there are multiple releases in the config";
format_error(no_releases_in_system) ->
    "No releases have been specified in the system!";
format_error({no_releases_for, RelName}) ->
    io_lib:format("No releases exist in the system for ~s!", [RelName]);
format_error({release_not_found, {RelName, RelVsn}}) ->
    io_lib:format("No releases exist in the system for ~p:~s!", [RelName, RelVsn]);
format_error({error, {Module, Reason}}) ->
    io_lib:format("~s~n", [Module:format_error(Reason)]).
