-module(rebar3_relx_extra_prv).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, release).
-define(DEPS, [compile]).

-record(rlx_extra_release, {name, version, apps, extend, includes}).

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
            {short_desc, "A rebar plugin"},
            {desc, "A rebar plugin"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.


-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    Relx = rebar_state:get(State, relx, []),
    _RelxAppMap = 
        lists:foldl(
          fun(Release, Acc) ->
                  add_release(Release, Acc)
          end, maps:new(), Relx),
    NRelx = [{add_providers, [rlx_prv_release_ext]}|Relx],
    NState = rebar_state:set(State, relx, NRelx),
    rebar_relx:do(rlx_prv_release, "release_ext", ?PROVIDER, NState).

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

add_release({release, RelInfo, Apps}, Acc) ->
    add_release({release, RelInfo, Apps, []}, Acc);
add_release({relase, RelInfo, Apps, Config}, Acc) ->
    RlxExtraRelease = rlx_extra_release(RelInfo, Apps, Config),
    #rlx_extra_release{name = Name} = RlxExtraRelease,
    maps:put(Name, RlxExtraRelease, Acc);
add_release(_, Acc) ->
    Acc.

rlx_extra_release(RelInfo, Apps, Config) ->
    RlxExtraRelease = rlx_base_release(RelInfo),
    NRlxExtraRelease = RlxExtraRelease#rlx_extra_release{apps = Apps},
    case lists:keyfind(include_releases, 1, Config) of
        false ->
            NRlxExtraRelease;
        {include_releases, Includes} ->
            NRlxExtraRelease#rlx_extra_release{includes = Includes}
    end.

rlx_base_release({RelName, RelVersion, {extend, Extend}}) ->
    #rlx_extra_release{name = RelName, version = RelVersion, extend = Extend};
rlx_base_release({RelName, RelVersion}) ->
    #rlx_extra_release{name = RelName, version = RelVersion}.
