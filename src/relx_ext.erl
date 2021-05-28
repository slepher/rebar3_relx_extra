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

-export([build_clusup/4, build_clusuptar/4]).

-export([format_error/1]).
%%%===================================================================
%%% API
%%%===================================================================
build_clusrel(Cluster, Apps, State) ->
    {ok, RealizedCluster, State1} =
        rlx_ext_resolve:solve_cluster(Cluster, Apps, State),
    {ok, State2} = rlx_app_assemble:do(RealizedCluster, State1),
    rlx_clusrel:do(RealizedCluster, State2).

build_clustar(RelNameOrUndefined, Apps, State) when is_atom(RelNameOrUndefined) ->
    {RelName, RelVsn} = pick_release_version(RelNameOrUndefined, State),
    Release = #{name => RelName,
                vsn  => RelVsn},
    build_clustar_1(Release, Apps, State);
build_clustar({RelName, RelVsn}, Apps, State) when is_atom(RelName) ,
                                                   is_list(RelVsn) ->
    Release = #{name => RelName,
                vsn => RelVsn},
    RealizedRelease = build_clustar_1(Release, Apps, State),
    {ok, rlx_state:add_realized_release(State, RealizedRelease)};
build_clustar(Release=#{name := _RelName,
                        vsn  := _RelVsn}, Apps, State) ->
    RealizedRelease = build_clustar_1(Release, Apps, State),
    {ok, rlx_state:add_realized_release(State, RealizedRelease)};
build_clustar(Release, _, _) ->
    ?RLX_ERROR({unrecognized_release, Release}).


build_clustar_1(#{name := RelName,
                 vsn := RelVsn}, Apps, RelxState) ->
    Release = rlx_state:get_configured_release(RelxState, RelName, RelVsn),
    {ok, RealizedRelease, RelxState1} =
        rlx_resolve:solve_release(Release, rlx_state:available_apps(RelxState, Apps)),
    rlx_clustar:do(RealizedRelease, RelxState1),
    RelxState.

build_clusup(ClusterName, ClusterVsn, UpFromVsn, RelxState) ->
    rlx_clusup:do(ClusterName, ClusterVsn, UpFromVsn, RelxState),
    RelxState.

build_clusuptar(Release, ToVsn, UpFromVsn, RelxState) ->
    RelxState.
%%--------------------------------------------------------------------
%% @doc
%% @spec
%% @end
%%--------------------------------------------------------------------

%%%===================================================================
%%% Internal functions
%%%===================================================================
pick_release(State) ->
    %% Here we will just get the highest versioned release and run that.
    case lists:sort(fun release_sort/2, maps:to_list(rlx_state:configured_releases(State))) of
        [{{RelName, RelVsn}, _} | _] ->
            {RelName, RelVsn};
        [] ->
            erlang:error(?RLX_ERROR(no_releases_in_system))
    end.

pick_release_version(undefined, State) ->
    pick_release(State);
pick_release_version(RelName, State) ->
    %% Here we will just get the lastest version for name RelName and run that.
    AllReleases = maps:to_list(rlx_state:configured_releases(State)),
    SpecificReleases = [Rel || Rel={{PossibleRelName, _}, _} <- AllReleases, PossibleRelName =:= RelName],
    case lists:sort(fun release_sort/2, SpecificReleases) of
        [{{RelName, RelVsn}, _} | _] ->
            {RelName, RelVsn};
        [] ->
            erlang:error(?RLX_ERROR({no_releases_for, RelName}))
    end.

-spec release_sort({{rlx_release:name(),rlx_release:vsn()}, term()},
                   {{rlx_release:name(),rlx_release:vsn()}, term()}) ->
                          boolean().
release_sort({{RelName, RelVsnA}, _},
             {{RelName, RelVsnB}, _}) ->
    rlx_util:parsed_vsn_lte(rlx_util:parse_vsn(RelVsnB), rlx_util:parse_vsn(RelVsnA));
release_sort({{RelA, _}, _}, {{RelB, _}, _}) ->
    %% The release names are different. When the releases are named differently
    %% we can not just take the lastest version. You *must* provide a default
    %% release name at least. So we throw an error here that the top can catch
    %% and return
    error(?RLX_ERROR({multiple_release_names, RelA, RelB})).

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
