%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2019, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 28 Feb 2019 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(rlx_ext_lib).

%% API
-export([sub_release_state/4]).
-export([update_rlx/1]).

%%%===================================================================
%%% API
%%%===================================================================

sub_release_state(State, Release, ReleaseName, ReleaseVsn) ->
    Config = rlx_release:config(Release),
    InitConfig = proplists:get_value(init_config, Config),
    OutputDir = rlx_state:output_dir(State),
    SubRelease = rlx_state:get_configured_release(State, ReleaseName, ReleaseVsn),
    SubConfig = rlx_release:config(SubRelease),
    State1 = rlx_state:default_configured_release(State, ReleaseName, ReleaseVsn),
    State2 = rlx_state:base_output_dir(State1, filename:join([OutputDir, "sub_releases"])),
    {ok, State3} = lists:foldl(fun rlx_config:load_terms/2, {ok, State2}, InitConfig),
    {ok, State4} = lists:foldl(fun rlx_config:load_terms/2, {ok, State3}, SubConfig),
    State4.

update_rlx(State) ->
    Relx = rebar_state:get(State, relx, []),
    RelxExt = rebar_state:get(State, relx_ext, []),
    case merge_relx_ext(Relx, RelxExt) of
        {ok, Relx1} ->
            Relx2 = [{add_providers, [rlx_prv_release_ext, rlx_prv_archive_ext]}|Relx1],
            {ok, rebar_state:set(State, relx, Relx2)};
        {error, Reason} ->
            {error, Reason}
    end.

rlx_state(Relx) ->
    State = rlx_state:new([], [release]),
    lists:foldl(fun rlx_config:load_terms/2, {ok, State}, Relx).
        

merge_relx_ext(Relx, RelxExt) ->
    case rlx_state(Relx) of
        {ok, RelxState} ->
            Result = 
                lists:foldl(
                  fun({release, {ReleaseName, ReleaseVsn}, SubReleases}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, [], Relx, RelxState)|Acc];
                     ({release, {ReleaseName, ReleaseVsn}, SubReleases, Config}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, Config, Relx, RelxState)|Acc];
                     (_Other, Acc) ->
                          Acc
                  end, [], RelxExt),
            case rebar3_relx_extra_lib:split_fails(
                   fun(Succ, Acc1) ->
                           [Succ|Acc1]
                   end, [], Result) of
                {ok, Releases} ->
                    {ok, Releases ++ Relx};
                {error, Reason} ->
                    {error, Reason}
            end;
        {error, Reason} ->
            {error, Reason}
    end.

release(ReleaseName, ReleaseVsn, SubReleases, Config, Relx, RelxState) ->
    Result = 
        lists:map(
          fun(SubReleaseName) when is_atom(SubReleaseName) ->
                  goals(SubReleaseName, ReleaseVsn, RelxState);
             ({SubReleaseName, SubReleaseVsn}) when is_atom(SubReleaseName) ->
                  goals(SubReleaseName, SubReleaseVsn, RelxState);
             (SubRelease) ->
                  {error, {invalid_sub_release, SubRelease}}
          end, SubReleases),
    case rebar3_relx_extra_lib:split_fails(
           fun(SubGoals, Acc1) ->
                   ordsets:union(ordsets:from_list(SubGoals), Acc1)
           end, ordsets:new(), Result) of
        {ok, Goals} ->
            InitConfig = 
                lists:map(
                  fun({Key, _}) ->
                          {Key, proplists:get_value(Key, Relx)}
                  end, Config),
            SubReleases1 = 
                lists:map(
                  fun(SubReleaseName) when is_atom(SubReleaseName) ->
                          {SubReleaseName, ReleaseVsn};
                     ({SubReleaseName, SubReleaseVsn}) when is_atom(SubReleaseName) ->
                          {SubReleaseName, SubReleaseVsn}
                  end, SubReleases),
            {ok, {release, {ReleaseName, ReleaseVsn}, Goals, [{ext, SubReleases1}, {init_config, InitConfig}|Config]}};
        {error, Reason} ->
            {error, Reason}
    end.

goals(ReleaseName, ReleaseVsn, RelxState) ->
    try rlx_state:get_configured_release(RelxState, ReleaseName, ReleaseVsn) of
        Release ->
            {ok, rlx_release:goals(Release)}
    catch
        _:not_found ->
            {error, {ReleaseName, ReleaseVsn, not_found}}
    end.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
