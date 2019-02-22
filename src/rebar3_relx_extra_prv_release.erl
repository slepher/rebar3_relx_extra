-module(rebar3_relx_extra_prv_release).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, release_ext).
%-define(DEPS, [compile]).
-define(DEPS, []).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([
            {name, ?PROVIDER},            % The 'user friendly' name of the task
            {module, ?MODULE},            % The module implementation of the task
            {bare, true},                 % The task can be run by the user, always true
            {deps, ?DEPS},                % The list of dependencies
            {example, "rebar3 rebar3 relx extra"}, % How to use the plugin
            {opts, relx:opt_spec_list()}, % list of options understood by the plugin
            {short_desc, "Build release of project ext."},
            {desc, "Build release of project ext"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    case update_rlx(State) of
        {ok, State1} ->
            Options = rebar_state:command_args(State1),
            OptionsList = split_options(Options, []),
            lists:foldl(
              fun(NOptions, {ok, Val}) ->
                      State2 = rebar_state:command_args(State1, NOptions),
                      case rebar_relx:do(rlx_prv_release_ext, "release_ext", ?PROVIDER, State2) of
                          {ok, _} ->
                              {ok, Val};
                          {error, Reason} ->
                              {error, Reason}
                      end;
                 (_, {error, Reason}) ->
                      {error, Reason}
              end, {ok, State1}, OptionsList);
        {error, Reason} ->
            {error, Reason}
    end.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

update_rlx(State) ->
    Relx = rebar_state:get(State, relx, []),
    RelxExt = rebar_state:get(State, relx_ext, []),
    case merge_relx_ext(Relx, RelxExt) of
        {ok, Relx1} ->
            Relx2 = [{add_providers, [rlx_prv_release_ext]}|Relx1],
            {ok, rebar_state:set(State, relx, Relx2)};
        {error, Reason} ->
            {error, Reason}
    end.

merge_relx_ext(Relx, RelxExt) ->
    case rlx_state(Relx) of
        {ok, RelxState} ->
            Result = 
                lists:foldl(
                  fun({release, {ReleaseName, ReleaseVsn}, SubReleases}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, [], RelxState)|Acc];
                     ({release, {ReleaseName, ReleaseVsn}, SubReleases, Config}, Acc) ->
                          [release(ReleaseName, ReleaseVsn, SubReleases, Config, RelxState)|Acc];
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

rlx_state(Relx) ->
    State = rlx_state:new([], [release]),
    lists:foldl(fun rlx_config:load_terms/2, {ok, State}, Relx).
        
release(ReleaseName, ReleaseVsn, SubReleases, Config, RelxState) ->
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
            SubReleases1 = 
                lists:map(
                  fun(SubReleaseName) when is_atom(SubReleaseName) ->
                          {SubReleaseName, ReleaseVsn};
                     ({SubReleaseName, SubReleaseVsn}) when is_atom(SubReleaseName) ->
                          {SubReleaseName, SubReleaseVsn}
                  end, SubReleases),
            {ok, {release, {ReleaseName, ReleaseVsn}, Goals, [{ext, SubReleases1}|Config]}};
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


split_options(["-n",ReleaseOptions|Rest], Acc) ->
    Releases = string:split(ReleaseOptions, "+", all),
    lists:map(
      fun(Release) ->
              lists:reverse(Acc) ++ ["-n",Release|Rest]
      end, Releases);
split_options([Value|Rest], Acc) ->
    split_options(Rest, [Value|Acc]);
split_options([], Acc) ->
    lists:reverse(Acc).

    
