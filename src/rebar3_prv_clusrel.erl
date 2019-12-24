
-module(rebar3_prv_clusrel).

-export([init/1, do/1, format_error/1]).

-define(PROVIDER, clusrel).
%% -define(DEPS, [compile]).
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
            {example, "rebar3 clusrel"}, % How to use the plugin
            {opts, relx:opt_spec_list()}, % list of options understood by the plugin
            {short_desc, "Build release of project ext."},
            {desc, "Build release of project ext"}
    ]),
    {ok, rebar_state:add_provider(State, Provider)}.

-spec do(rebar_state:t()) -> {ok, rebar_state:t()} | {error, string()}.
do(State) ->
    rebar3_relx_extra_lib:do(rlx_prv_clusrel, "clusrel", ?PROVIDER, State).

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).
