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
-export([load/2]).

%%%===================================================================
%%% API
%%%===================================================================

load({cluster, {ClusName, ClusVsn}, Releases}, State) ->

    {ok, State};
load({cluster, {ClusName, ClusVsn}, Releases, Config}, State) ->
    {ok, State};
load({default_cluster, {ClusName, ClusVsn}}, State) ->
    State1 = rlx_ext_state:default_cluster_name(State, ClusName),
    State2 = rlx_ext_state:default_cluster_vsn(State1, ClusVsn),
    {ok, State2};
load({default_cluster, ClusName}, State) when is_atom(ClusName) ->
    State1 = rlx_ext_state:default_cluster_name(State, ClusName),
    {ok, State1};
load(_, Error={error, _}) ->
    erlang:error(?RLX_ERROR(Error));
load(InvalidTerm, {ok, State}) ->
    Warning = {invalid_term, InvalidTerm},
    case rlx_state:warnings_as_errors(State) of
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
