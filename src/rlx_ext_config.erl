%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2021, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 May 2021 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_ext_config).

-include_lib("relx/src/relx.hrl").

%% API
-export([to_state/2]).
-export([load/2]).

%%%===================================================================
%%% API
%%%===================================================================
to_state(RelxConfig, RelxExtConfig) ->
    case rlx_config:to_state(RelxConfig) of
        {ok, RelxState} ->
            RelxExtState = rlx_ext_state:new(RelxState),
            lists:foldl(fun load/2, {ok, RelxExtState}, RelxExtConfig);
        {error, Reason} ->
            {error, Reason}
    end.

load({cluster, {ClusName, ClusVsn}, Releases}, {ok, State}) ->
    State1 = add_cluster(ClusName, ClusVsn, Releases, [], State),
    {ok, State1};
load({cluster, {ClusName, ClusVsn}, Releases, Config}, {ok, State}) ->
    State1 = add_cluster(ClusName, ClusVsn, Releases, Config, State),
    {ok, State1};
load({default_cluster, ClusName}, {ok, State}) when is_atom(ClusName) ->
    State1 = rlx_ext_state:default_cluster_name(State, ClusName),
    {ok, State1};
load({include_apps, Apps}, {ok, State}) ->
    State1 = rlx_ext_state:include_apps(State, Apps),
    {ok, State1};
load(_, Error={error, _}) ->
    erlang:error(?RLX_ERROR(Error));
load(InvalidTerm, {ok, State}) ->
    RelxState = rlx_ext_state:rlx_state(State),
    Warning = {invalid_term, InvalidTerm},
    case rlx_state:warnings_as_errors(RelxState) of
        true ->
            erlang:error(?RLX_ERROR(Warning));
        false ->
            rebar_api:warn(format_error(Warning), []),
            {ok, State}
    end.

    
format_error({bad_system_libs, SetSystemLibs}) ->
    io_lib:format("Config value for system_libs must be a boolean or directory but found: ~p",
                  [SetSystemLibs]);
format_error({invalid_term, InvalidTerm}) ->
    io_lib:format("Unknown term found in relx configuration: ~p", [InvalidTerm]).

add_cluster(ClusName, ClusVsn, Releases, Config, RlxState) ->
    Cluster = rlx_cluster:new(ClusName, ClusVsn),
    Cluster1 = 
        lists:foldl(
          fun(Release, ClusAcc) ->
                  case find_release(Release, RlxState) of
                      {ok, ConfiguredRelease} ->
                          rlx_cluster:add_release(ClusAcc, ConfiguredRelease);
                      error ->
                          ?RLX_ERROR({cound_not_find_release, Release})
                  end
          end, Cluster, Releases),
    Cluster2 = rlx_cluster:config(Cluster1, Config),
    rlx_ext_state:add_cluster(RlxState, Cluster2).

find_release(RelName, RlxState) when is_atom(RelName) ->
    rlx_ext_state:find_release(RelName, RlxState);
find_release({RelName, RelVsn}, RlxState) when is_atom(RelName) ->
    rlx_ext_state:find_release(RelName, RelVsn, RlxState).
