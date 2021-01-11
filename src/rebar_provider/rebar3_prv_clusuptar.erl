-module(rebar3_prv_clusuptar).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, clusuptar).
-define(DEPS, []).

%% ===================================================================
%% Public API
%% ===================================================================
-spec init(rebar_state:t()) -> {ok, rebar_state:t()}.
init(State) ->
    Provider = providers:create([{name, ?PROVIDER},
                                 {module, ?MODULE},
                                 {bare, true},
                                 {deps, ?DEPS},
                                 {example, "rebar3 clusup"},
                                 {short_desc, "Create clusup of cluster release."},
                                 {desc, "Create clusup of cluster release."},
                                 {opts, rebar_relx:opt_spec_list()}]),
    State1 = rebar_state:add_provider(State, Provider),
    {ok, State1}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    rebar3_relx_extra_lib:do(rlx_prv_clusuptar, "clusuptar", ?PROVIDER, State).

-spec format_error(any()) ->  iolist().
format_error(Reason) when is_list(Reason)->
    Reason;
format_error(Reason) ->
    io_lib:format("~p", [Reason]).
