
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
    State2 = rlx_state:base_output_dir(State1, filename:join([OutputDir, "clients"])),
    {ok, State3} = lists:foldl(fun rlx_config:load_terms/2, {ok, State2}, InitConfig),
    {ok, State4} = lists:foldl(fun rlx_config:load_terms/2, {ok, State3}, SubConfig),
    State4.

update_rlx(State) ->
    Relx = rebar_state:get(State, relx, []),
    RelxExt = rebar_state:get(State, relx_ext, []),
    case merge_relx_ext(Relx, RelxExt) of
        {ok, Relx1} ->
            Relx2 = [{add_providers, [rlx_prv_release_ext, rlx_prv_archive_ext, rlx_prv_clusup]}|Relx1],
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
            RlxReleaseMap = rlx_releases(RelxState),
            Result = 
                lists:foldl(
                  fun({release, {ReleaseName, ReleaseVsn}, SubReleases}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, [], RlxReleaseMap, Relx, RelxState)|Acc];
                     ({release, {ReleaseName, ReleaseVsn}, SubReleases, Config}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, Config, RlxReleaseMap, Relx, RelxState)|Acc];
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

rlx_releases(State) ->
    Releases = rlx_state:configured_releases(State),
    RelVsns = ec_dictionary:keys(Releases),
    RlxReleaseMap = 
    lists:foldl(
      fun({ReleaseName, ReleaseVsn}, Acc) ->
              ReleaseVsns = maps:get(ReleaseName, Acc, []),
              ReleaseVsns1 = [ReleaseVsn|ReleaseVsns],
              maps:put(ReleaseName, ReleaseVsns1, Acc)
      end, maps:new(), RelVsns),
    maps:map(
      fun(_ReleaseName, ReleaseVsns) ->
              lists:sort(
                fun(R1, R2) ->
                        ec_semver:gte(R1, R2)
                end, ReleaseVsns)
      end, RlxReleaseMap).

release(ReleaseName, ReleaseVsn, SubReleases, Config, RlxReleaseMap, Relx, RelxState) ->
    Result = 
        lists:map(
          fun(SubReleaseName) when is_atom(SubReleaseName) ->
                  case get_last_release(SubReleaseName, RlxReleaseMap) of
                      {ok, SubReleaseVsn} ->
                          goals(SubReleaseName, SubReleaseVsn, RelxState);
                      {error, Reason} ->
                          {error, Reason}
                  end;
             ({SubReleaseName, SubReleaseVsn}) when is_atom(SubReleaseName) ->
                  goals(SubReleaseName, SubReleaseVsn, RelxState);
             (SubRelease) ->
                  {error, {invalid_sub_release, SubRelease}}
          end, SubReleases),
    case rebar3_relx_extra_lib:split_fails(
           fun({SubReleaseName, SubRelaseVsn, SubGoals}, {SubReleasesAcc, GoalsAcc}) ->
                   GoalsAcc1 = ordsets:union(ordsets:from_list(SubGoals), GoalsAcc),
                   SubReleasesAcc1 = [{SubReleaseName, SubRelaseVsn}|SubReleasesAcc],
                   {SubReleasesAcc1, GoalsAcc1}
           end, {[], ordsets:new()}, Result) of
        {ok, {SubReleases1, Goals}} ->
            InitConfig = 
                lists:map(
                  fun({Key, _}) ->
                          {Key, proplists:get_value(Key, Relx)}
                  end, Config),
            {ok, {release, {ReleaseName, ReleaseVsn}, Goals, [{ext, SubReleases1}, {init_config, InitConfig}|Config]}};
        {error, Reason} ->
            {error, Reason}
    end.

get_last_release(SubReleaseName, RlxReleaseMap) ->
   case maps:find(SubReleaseName, RlxReleaseMap) of
       {ok, [ReleaseVsn|_T]} ->
           {ok, ReleaseVsn};
       error ->
           {error, {no_subrelease, SubReleaseName}}
   end.


goals(ReleaseName, ReleaseVsn, RelxState) ->
    try rlx_state:get_configured_release(RelxState, ReleaseName, ReleaseVsn) of
        Release ->
            {ok, {ReleaseName, ReleaseVsn, rlx_release:goals(Release)}}
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
