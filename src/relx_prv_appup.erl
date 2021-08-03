%%%-------------------------------------------------------------------
%%% @author Chen Slepher <slepheric@gmail.com>
%%% @copyright (C) 2020, Chen Slepher
%%% @doc
%%%
%%% @end
%%% Created : 27 Feb 2020 by Chen Slepher <slepheric@gmail.com>
%%%-------------------------------------------------------------------
-module(relx_prv_appup).

-export([do/6, format_error/1]).


-define(SUPPORTED_BEHAVIOURS, [gen_server,
                               gen_fsm,
                               gen_statem,
                               gen_event,
                               application,
                               supervisor]).


%% ===================================================================
%% Public API
%% ===================================================================
do(ClusName, ClusVsn, UpFromVsn, Apps, Opts, State) ->
    CurrentRelPath = get_current_rel_path(State, ClusName),
    rebar_api:info("current release, name: ~s, version: ~s, upfrom version: ~s", [ClusName, ClusVsn, UpFromVsn]),
    PreviousRelPath =
        case proplists:get_value(previous, Opts, undefined) of
            undefined -> CurrentRelPath;
            P -> P
        end,
    rebar_api:info("previous release: ~s", [PreviousRelPath]),
    rebar_api:info("current release: ~s", [CurrentRelPath]),

    %% Run some simple checks
    true = rebar3_appup_utils:prop_check(ClusVsn =/= UpFromVsn,
                                         "current (~p) and previous (~p) release versions are the same",
                                         [ClusVsn, UpFromVsn]),

    %% Find all the apps that have been upgraded
    {AddApps0, UpgradeApps0, RemoveApps} = get_apps(ClusName, PreviousRelPath, UpFromVsn, CurrentRelPath, ClusVsn),

  
    generate_appups(
      CurrentRelPath, PreviousRelPath, ClusVsn, Apps, AddApps0, UpgradeApps0, RemoveApps, State),
    {ok, State}.

-spec format_error(any()) ->  iolist().
format_error(Reason) ->
    io_lib:format("~p", [Reason]).

get_current_rel_path(State, Name) ->
    RelxState = relx_ext_state:rlx_state(State),
    Dir = rlx_state:base_output_dir(RelxState),
    filename:join(Dir, Name).

get_apps(Name, OldVerPath, OldVer, NewVerPath, NewVer) ->
    OldApps = get_clus_apps(Name, OldVer, OldVerPath),
    rebar_api:debug("previous version apps: ~p", [OldApps]),

    NewApps = get_clus_apps(Name, NewVer, NewVerPath),
    rebar_api:debug("current version apps: ~p", [NewApps]),

    AddedApps = app_list_diff(NewApps, OldApps),
    Added = lists:map(fun(AppName) ->
                        AddedAppVer = proplists:get_value(AppName, NewApps),
                        {add, AppName, AddedAppVer}
                      end, AddedApps),
    rebar_api:debug("added: ~p", [Added]),

    Removed = lists:map(fun(AppName) ->
                            RemovedAppVer = proplists:get_value(AppName, OldApps),
                            {remove, AppName, RemovedAppVer}
                        end, app_list_diff(OldApps, NewApps)),
    rebar_api:debug("removed: ~p", [Removed]),

    Upgraded = lists:filtermap(fun(AppName) ->
                                OldAppVer = proplists:get_value(AppName, OldApps),
                                NewAppVer = proplists:get_value(AppName, NewApps),
                                case OldAppVer /= NewAppVer of
                                    true ->
                                        {true, {upgrade, AppName, {OldAppVer, NewAppVer}}};
                                    false -> false
                                end
                               end, proplists:get_keys(NewApps) -- AddedApps),
    rebar_api:debug("upgraded: ~p", [Upgraded]),
    {Added, Upgraded, Removed}.

get_clus_apps(Name, Version, Path) ->
    Filename = filename:join([Path, "releases", Version, atom_to_list(Name) ++ ".clus"]),
    case filelib:is_file(Filename) of
        true ->
            case file:consult(Filename) of
                {ok, [{cluster, _Name, _Version, _Release, Apps}]} ->
                    Apps;
                _ ->
                    rebar_api:abort("Failed to parse ~s~n", [Filename])
            end;
        false ->
            rebar_api:abort("file ~s not exists ~n", [Filename])
    end.

%% @spec app_list_diff([any()],[any()]) -> [any()].
app_list_diff(List1, List2) ->
    List3 = lists:umerge(lists:sort(proplists:get_keys(List1)),
                         lists:sort(proplists:get_keys(List2))),
    List3 -- proplists:get_keys(List2).


generate_appups(CurrentRelPath, PreviousRelPath, _CurrentVer, AppDirs,
                AddApps0, UpgradeApps0, RemoveApps, State) ->

    %% Create a list of apps that don't already have appups
    UpgradeApps1 = gen_appup_which_apps(UpgradeApps0, AppDirs),
    AddApps = gen_appup_which_apps(AddApps0, AppDirs),
    UpgradeApps = UpgradeApps1 ++ AddApps,
    rebar_api:debug("generating .appup for apps: ~p", [AddApps ++ UpgradeApps ++ RemoveApps]),

    %% Generate appup files for apps
    lists:foreach(fun(App) ->
                    generate_appup_files(CurrentRelPath, PreviousRelPath,
                                         App, AppDirs, State)
                  end, AddApps ++ UpgradeApps),
    ok.

gen_appup_which_apps(Apps, AppDirs) ->
    gen_appup_which_apps(Apps, AppDirs, []).

gen_appup_which_apps([App|T], AppDirs, Acc) ->
    AppName = element(2, App),
    case maps:find(AppName, AppDirs) of
        {ok, #{dir := AppDir}} ->
            Appup = filename:join([AppDir, "ebin", atom_to_list(AppName) ++ ".appup"]),
            case filelib:is_file(Appup) of
                true ->
                    {_, Vsn} = appup_info(Appup),
                    rebar_api:info("appup ~p for ~p ~s exists", [Vsn, AppName, Appup]),
                    gen_appup_which_apps(T, AppDirs, Acc);
                false ->
                    gen_appup_which_apps(T, AppDirs, [App|Acc])
            end;
        error ->
            gen_appup_which_apps(T, AppDirs, [App|Acc])
    end;
gen_appup_which_apps([], _AppDirs, Acc) ->
    lists:reverse(Acc).

%% @spec appup_info(string()) -> {App :: atom(),
%%                                ToVersion :: string()}.
appup_info(File) ->
    {ok, [{ToVersion, _, _}]} = file:consult(File),
    {file_to_name(File), ToVersion}.

%% @spec file_to_name(atom() | binary() | [atom() | [any()] | char()]) -> binary() | string().
file_to_name(File) ->
    filename:rootname(filename:basename(File)).

generate_appup_files(_, _, {upgrade, _App, {undefined, _}}, _, _) -> ok;
generate_appup_files(NewVerPath, _OldVerPath,
                     {add, App, Version},
                     AppDirs, State) ->

    UpgradeInstructions = [{add_application, App, permanent}],
    DowngradeInstructions = lists:reverse(lists:map(fun invert_instruction/1,
                                                    UpgradeInstructions)),
    NewRelEbinDir = filename:join([NewVerPath, "lib",
                                   atom_to_list(App) ++ "-" ++ Version, "ebin"]),
    ok = write_appup(App, ".*", Version, NewRelEbinDir,
                     UpgradeInstructions, DowngradeInstructions,
                     AppDirs, State),
    ok;
generate_appup_files(NewVerPath, OldVerPath,
                     {upgrade, App, {OldVer, NewVer}},
                     AppDirs, State) ->
    OldRelEbinDir = filename:join([OldVerPath, "lib",
                                atom_to_list(App) ++ "-" ++ OldVer, "ebin"]),
    NewRelEbinDir = filename:join([NewVerPath, "lib",
                                atom_to_list(App) ++ "-" ++ NewVer, "ebin"]),

    {AddedFiles, DeletedFiles, ChangedFiles} = beam_lib:cmp_dirs(NewRelEbinDir, OldRelEbinDir),
    rebar_api:debug("beam files:", []),
    rebar_api:debug("   added: ~p", [AddedFiles]),
    rebar_api:debug("   deleted: ~p", [DeletedFiles]),
    rebar_api:debug("   changed: ~p", [ChangedFiles]),

    %% generate a module dependency tree
    ModDeps = module_dependencies(AddedFiles ++ ChangedFiles),
    rebar_api:debug("deps: ~p", [ModDeps]),

    Added = lists:map(fun(File) ->
                        generate_instruction(add_module, ModDeps, File, State)
                      end, AddedFiles),
    Deleted = lists:map(fun(File) ->
                            generate_instruction(delete_module, ModDeps, File, State)
                        end, DeletedFiles),
    Changed = lists:map(fun(File) ->
                            generate_instruction(upgrade, ModDeps, File, State)
                        end, ChangedFiles),

    UpgradeInstructions0 = lists:append([Added, Changed, Deleted]),
    %% check for updated supervisors, we'll need to check their child spec
    %% and see if any childs were added or removed
    UpgradeInstructions1 = apply_supervisor_child_updates(UpgradeInstructions0,
                                                          Added, Deleted,
                                                          OldRelEbinDir, NewRelEbinDir),
    UpgradeInstructions = lists:flatten(UpgradeInstructions1),
    rebar_api:debug("upgrade instructions: ~p", [UpgradeInstructions]),
    DowngradeInstructions0 = lists:reverse(lists:map(fun invert_instruction/1,
                                                     UpgradeInstructions1)),
    DowngradeInstructions = lists:flatten(DowngradeInstructions0),
    rebar_api:debug("downgrade instructions: ~p", [DowngradeInstructions]),

    ok = write_appup(App, OldVer, NewVer, NewRelEbinDir,
                     UpgradeInstructions, DowngradeInstructions, AppDirs, State),
    ok.

%% @spec write_appup(atom(),_,_,atom() | binary() | [atom() | [any()] | char()],[any()],[{'add_module',_} | {'apply',{_,_,_}} | {'delete_module',_} | {'remove_application',_} | {'add_application',_,'permanent'} | {'update',_,'supervisor'} | {'load_module',_,_,_,_} | {'update',_,{_,_},_,_,_}],[{'plugin_dir',_} | {'purge_opts',[any()]},...],_) -> 'ok'.
write_appup(App, OldVer, NewVer, NewRelEbinDir,
            UpgradeInstructions0, DowngradeInstructions0, AppDirs, State) ->
    AppUpFiles = [filename:join([NewRelEbinDir, atom_to_list(App) ++ ".appup"])],

    rebar_api:debug(
        "Upgrade instructions before merging with .appup.pre.src and "
        ".appup.post.src files: ~p",
        [UpgradeInstructions0]),
    rebar_api:debug(
        "Downgrade instructions before merging with .appup.pre.src and "
        ".appup.post.src files: ~p",
        [DowngradeInstructions0]),
    {UpgradeInstructions, DowngradeInstructions} =
        merge_instructions(App, AppUpFiles, UpgradeInstructions0, DowngradeInstructions0, OldVer, NewVer, AppDirs),
    rebar_api:debug(
        "Upgrade instructions after merging with .appup.pre.src and "
        ".appup.post.src files:\n~p\n",
        [UpgradeInstructions]),
    rebar_api:debug(
        "Downgrade instructions after merging with .appup.pre.src and "
        ".appup.post.src files:\n~p\n",
        [DowngradeInstructions]),

    {ok, AppupTemplate} = file:read_file(relx_ext_state:appup_template(State)),

    %% write each of the .appup files
    lists:foreach(fun(AppUpFile) ->
                    AppupCtx = [{"app", App},
                                {"now", rebar3_appup_utils:now_str()},
                                {"new_vsn", NewVer},
                                {"old_vsn", OldVer},
                                {"upgrade_instructions",
                                    io_lib:fwrite("~.9p", [UpgradeInstructions])},
                                {"downgrade_instructions",
                                    io_lib:fwrite("~.9p", [DowngradeInstructions])}],
                    EscFun = fun(X) -> X end,
                    AppUp = bbmustache:render(AppupTemplate, AppupCtx, [{escape_fun, EscFun}]),
                    rebar_api:info("Generated appup (~p <-> ~p) for ~p in ~p",
                        [OldVer, NewVer, App, AppUpFile]),
                    ok = file:write_file(AppUpFile, AppUp)
                  end, AppUpFiles),
    ok.

%% @spec module_dependencies([string() | {[any()],[any()]}]) -> [{atom(),[any()]}].
module_dependencies(Files) ->
    %% build a unique list of directories holding the supplied files
    Dirs0 = lists:map(fun({File, _}) ->
                            filename:dirname(File);
                         (File) ->
                            filename:dirname(File)
                      end, Files),
    Dirs = lists:usort(Dirs0),
    %% start off xref
    {ok, _} = xref:start(xref),
    %% add each of the directories to the xref path

    lists:foreach(fun(Dir) ->
                    {ok, _} = xref:add_directory(xref, Dir, [{warnings, false}])
                  end, Dirs),
    Mods = [list_to_atom(file_to_name(F)) || {F, _} <- Files],
    module_dependencies(Mods, Mods, []).

%% @spec module_dependencies([atom()],[atom()],[{atom(),[any()]}]) -> [{atom(),[any()]}].
module_dependencies([], _Mods, Acc) ->
    xref:stop(xref),
    Acc;
module_dependencies([Mod | Rest], Mods, Acc) ->
    {ok, Deps0} = xref:analyze(xref, {module_call, Mod}),
    %% remove self
    Deps1 = Deps0 -- [Mod],
    %% intersect with modules being changed
    Set0 = sets:from_list(Deps1),
    Set1 = sets:from_list(Mods),
    Deps = sets:to_list(sets:intersection(Set0, Set1)),
    module_dependencies(Rest, Mods, Acc ++ [{Mod, Deps}]).

%% @spec generate_instruction('add_module' | 'delete_module' | 'upgrade',[{atom(),[any()]}],atom() | binary() | [atom() | [any()] | char()] | {atom() | binary() | string() | tuple(),_},[{'plugin_dir',_} | {'purge_opts',[any()]},...]) -> {'delete_module',atom()} | {'add_module',atom(),_} | {'update',atom() | tuple(),'supervisor'} | {'load_module',atom() | tuple(),_,_,_} | {'update',atom() | tuple(),{'advanced',[]},_,_,_}.
generate_instruction(add_module, ModDeps, File, _Opts) ->
    Name = list_to_atom(file_to_name(File)),
    Deps = proplists:get_value(Name, ModDeps, []),
    {add_module, Name, Deps};
generate_instruction(delete_module, ModDeps, File, _Opts) ->
    Name = list_to_atom(file_to_name(File)),
    _Deps = proplists:get_value(Name, ModDeps, []),
    % TODO: add dependencies to delete_module, fixed in OTP commit a4290bb3
    % {delete_module, Name, Deps};
    {delete_module, Name};
%generate_instruction(added_application, Application, _, _Opts) ->
%    {add_application, Application, permanent};
%generate_instruction(removed_application, Application, _, _Opts) ->
%    {remove_application, Application};
%generate_instruction(restarted_application, Application, _, _Opts) ->
%    {restart_application, Application};
generate_instruction(upgrade, ModDeps, {File, _}, Opts) ->
    {ok, {Name, List}} = beam_lib:chunks(File, [attributes, exports]),
    Behavior = get_behavior(List),
    CodeChange = is_code_change(List),
    Deps = proplists:get_value(Name, ModDeps, []),
    generate_instruction_advanced(Name, Behavior, CodeChange, Deps, Opts).

%% @spec generate_instruction_advanced(atom() | tuple(),_,'code_change' | 'undefined',_,[{'plugin_dir',_} | {'purge_opts',[any()]},...]) -> {'update',atom() | tuple(),'supervisor'} | {'load_module',atom() | tuple(),_,_,_} | {'update',atom() | tuple(),{'advanced',[]},_,_,_}.
generate_instruction_advanced(Name, undefined, undefined, Deps, State) ->
    PrePurge = relx_ext_state:pre_purge(State),
    PostPurge = relx_ext_state:post_purge(State),
    %% Not a behavior or code change, assume purely functional
    {load_module, Name, PrePurge, PostPurge, Deps};
generate_instruction_advanced(Name, supervisor, _, _, _Opts) ->
    %% Supervisor
    {update, Name, supervisor};
generate_instruction_advanced(Name, _, code_change, Deps, State) ->
    PrePurge = relx_ext_state:pre_purge(State),
    PostPurge = relx_ext_state:post_purge(State),
    %% Includes code_change export
    {update, Name, {advanced, []}, PrePurge, PostPurge, Deps};
generate_instruction_advanced(Name, _, _, Deps, State) ->
    PrePurge = relx_ext_state:pre_purge(State),
    PostPurge = relx_ext_state:post_purge(State),
    %% Anything else
    {load_module, Name, PrePurge, PostPurge, Deps}.

generate_supervisor_child_instruction(new, Mod, Worker) ->
    [{update, Mod, supervisor},
     {apply, {supervisor, restart_child, [Mod, Worker]}}];
generate_supervisor_child_instruction(remove, Mod, Worker) ->
    [{apply, {supervisor, terminate_child, [Mod, Worker]}},
     {apply, {supervisor, delete_child, [Mod, Worker]}},
     {update, Mod, supervisor}].

invert_instruction({load_module, Name, PrePurge, PostPurge, Deps}) ->
    {load_module, Name, PrePurge, PostPurge, Deps};
invert_instruction({add_module, Name, _Deps}) ->
    % TODO: add dependencies to delete_module, fixed in OTP commit a4290bb3
    % {delete_module, Name, Deps};
    {delete_module, Name};
invert_instruction({delete_module, Name}) ->
    % TODO: add dependencies to add_module, fixed in OTP commit a4290bb3
    % {add_module, Name, Deps};
    {add_module, Name};
invert_instruction({add_application, Application, permanent}) ->
    {remove_application, Application};
invert_instruction({remove_application, Application}) ->
    {add_application, Application, permanent};
invert_instruction({update, Name, supervisor}) ->
    {update, Name, supervisor};
invert_instruction({update, Name, {advanced, []}, PrePurge, PostPurge, Deps}) ->
    {update, Name, {advanced, []}, PrePurge, PostPurge, Deps};
invert_instruction([{update, Name, supervisor},
                    {apply, {supervisor, restart_child, [Sup, Worker]}}]) ->
    [{apply, {supervisor, terminate_child, [Sup, Worker]}},
     {apply, {supervisor, delete_child, [Sup, Worker]}},
     {update, Name, supervisor}];
invert_instruction([{apply, {supervisor, terminate_child, [Sup, Worker]}},
                    {apply, {supervisor, delete_child, [Sup, Worker]}},
                    {update, Name, supervisor}]) ->
    [{update, Name, supervisor},
     {apply, {supervisor, restart_child, [Sup, Worker]}}].


%% @spec get_behavior([{'abstract_code' | 'atoms' | 'attributes' | 'compile_info' | 'exports' | 'imports' | 'indexed_imports' | 'labeled_exports' | 'labeled_locals' | 'locals' | [any(),...],'no_abstract_code' | binary() | [any()] | {_,_}}]) -> any().
get_behavior(List) ->
    Attributes = proplists:get_value(attributes, List),
    case proplists:get_value(behavior, Attributes, []) ++
         proplists:get_value(behaviour, Attributes, []) of
        [] -> undefined;
        Bs -> select_behaviour(
                lists:sort(
                  drop_unknown_behaviours(Bs)))
    end.

drop_unknown_behaviours(Bs) ->
    drop_unknown_behaviours(Bs, []).

drop_unknown_behaviours([], Acc) -> Acc;
drop_unknown_behaviours([B|Rest], Acc0) ->
    Acc = case supported_behaviour(B) of
            true -> [B|Acc0];
            false -> Acc0
          end,
    drop_unknown_behaviours(Rest, Acc).

supported_behaviour(B) ->
    lists:member(B, ?SUPPORTED_BEHAVIOURS).

select_behaviour([]) -> undefined;
select_behaviour([B]) -> B;
%% apply the supervisor upgrade when a module is both it and application
select_behaviour([application, supervisor]) -> supervisor.

%% @spec is_code_change([{'abstract_code' | 'atoms' | 'attributes' | 'compile_info' | 'exports' | 'imports' | 'indexed_imports' | 'labeled_exports' | 'labeled_locals' | 'locals' | [any(),...],'no_abstract_code' | binary() | [any()] | {_,_}}]) -> 'code_change' | 'undefined'.
is_code_change(List) ->
    Exports = proplists:get_value(exports, List),
    case proplists:is_defined(code_change, Exports) orelse
        proplists:is_defined(system_code_change, Exports) of
        true ->
            code_change;
        false ->
            undefined
    end.

apply_supervisor_child_updates(Instructions, Added, Deleted,
                               OldRelEbinDir, NewRelEbinDir) ->
    apply_supervisor_child_updates(Instructions, Added, Deleted,
                                   OldRelEbinDir, NewRelEbinDir, []).

apply_supervisor_child_updates([], _, _, _, _, Acc) -> Acc;
apply_supervisor_child_updates([{update, Name, supervisor} | Rest],
                               Added, Deleted,
                               OldRelEbinDir, NewRelEbinDir, Acc) ->
    Instructions = 
    case get_supervisor_spec(Name, NewRelEbinDir) of
        {ok, NewSupervisorSpec} ->
            case get_supervisor_spec(Name, OldRelEbinDir) of
                {ok, OldSupervisorSpec} ->
                    rebar_api:debug("old supervisor spec: ~p",
                                    [OldSupervisorSpec]),
                    rebar_api:debug("new supervisor spec: ~p",
                                    [NewSupervisorSpec]),
                    Diff = diff_supervisor_spec(OldSupervisorSpec,
                                                NewSupervisorSpec),
                    NewWorkers = proplists:get_value(new_workers, Diff),
                    RemovedWorkers = proplists:get_value(removed_workers, Diff),
                    rebar_api:debug("supervisor workers added: ~p",
                                    [NewWorkers]),
                    rebar_api:debug("supervisor workers removed: ~p",
                                    [RemovedWorkers]),
                    AddInstructions = [generate_supervisor_child_instruction(new, Name, N) ||
                                          N <- NewWorkers],
                    RemoveInstructions = [generate_supervisor_child_instruction(remove, Name, R) ||
                                             R <- RemovedWorkers],
                    AddInstructions ++ RemoveInstructions;
                {error, Reason} ->
                    rebar_api:info("could not obtain supervisor ~p spec, unable to generate "
                                   "supervisor appup instructions ~p", [Name, Reason]),
                    []

            end;
        {error, Reason} ->
            rebar_api:info("could not obtain supervisor ~p spec, unable to generate "
                           "supervisor appup instructions ~p", [Name, Reason]),
            []
    end,
    Instructions1 = ensure_supervisor_update(Name, Instructions),
    apply_supervisor_child_updates(Rest, Added, Deleted,
                                   OldRelEbinDir, NewRelEbinDir,
                                   Acc ++ Instructions1);
apply_supervisor_child_updates([Else | Rest],
                               Added, Deleted,
                               OldRelEbinDir, NewRelEbinDir, Acc) ->
    apply_supervisor_child_updates(Rest, Added, Deleted,
                                   OldRelEbinDir, NewRelEbinDir, Acc ++ [Else]).

ensure_supervisor_update(Name, []) ->
    [{update, Name, supervisor}];
 ensure_supervisor_update(_, Instructions) ->
    Instructions.

get_supervisor_spec(Module, EbinDir) ->
    Beam = rebar3_appup_utils:beam_rel_path(EbinDir, atom_to_list(Module)),
    {module, Module} = rebar3_appup_utils:load_module_from_beam(Beam, Module),
    case guess_supervisor_init_arg(Module, Beam) of
        {ok, Arg} ->
            rebar_api:debug("supervisor init arg: ~p", [Arg]),
            Spec = case catch Module:init(Arg) of
                       {ok, S} -> S;
                       _ ->
                           rebar_api:info("could not obtain supervisor ~p spec, unable to generate "
                                          "supervisor appup instructions", [Module]),
                           undefined
                   end,
            rebar3_appup_utils:unload_module_from_beam(Beam, Module),
            {ok, Spec};
        {error, Reason} ->
            {error, Reason}
    end.

diff_supervisor_spec({_, Spec1}, {_, Spec2}) ->
    Workers1 = supervisor_spec_workers(Spec1, []),
    Workers2 = supervisor_spec_workers(Spec2, []),
    [{new_workers, Workers2 -- Workers1},
     {removed_workers, Workers1 -- Workers2}];
diff_supervisor_spec(_, _) ->
    [{new_workers, []}, {removed_workers, []}].

supervisor_spec_workers([], Acc) -> Acc;
supervisor_spec_workers([{_, {Mod, _F, _A}, _, _, worker, _} | Rest], Acc) ->
    supervisor_spec_workers(Rest, Acc ++ [Mod]);
supervisor_spec_workers([#{start := {Mod, _F, _A}, type := worker} | Rest], Acc) ->
    supervisor_spec_workers(Rest, Acc ++ [Mod]);
supervisor_spec_workers([#{start := {Mod, _F, _A}} | Rest], Acc) ->
    supervisor_spec_workers(Rest, Acc ++ [Mod]);
supervisor_spec_workers([_ | Rest], Acc) ->
    supervisor_spec_workers(Rest, Acc).

guess_supervisor_init_arg(Module, Beam) ->
    %% obtain the abstract code and from that try and guess what
    %% are valid arguments for the supervisor init/1 method
    Forms =  case rebar3_appup_utils:get_abstract_code(Module, Beam) of
                no_abstract_code=E ->
                    {error, E};
                encrypted_abstract_code=E ->
                    {error, E};
                {raw_abstract_v1, Code} ->
                    epp:interpret_file_attribute(Code)
              end,
    case get_supervisor_init_arg_abstract(Forms) of
         {ok, AbsArg} ->
            rebar_api:debug("supervisor abstract init arg: ~p", [AbsArg]),
            Arg = generate_supervisor_init_arg(AbsArg),
            {ok, Arg};
        {error, Reason} ->
            {error, Reason}
    end.

get_supervisor_init_arg_abstract(Forms) ->
    case lists:filtermap(fun({function, _, init, 1, [Clause]}) ->
                                 %% currently not supporting more that one function clause
                                 %% for the Mod:init/1 supervisor callback
                                 %% extract the argument from the function clause
                                 {clause, _, [Arg], _, _} = Clause,
                                 {true, Arg};
                           (_) -> false
                         end, Forms) of
        [L] ->
            {ok, L};
        [] ->
            {error, non_supervisor_init_arg_abstract}
    end.

generate_supervisor_init_arg({nil, _}) -> [];
generate_supervisor_init_arg({var, _, _}) -> undefined;
generate_supervisor_init_arg({cons, _, Head, Rest}) ->
    [generate_supervisor_init_arg(Head) | generate_supervisor_init_arg(Rest)];
generate_supervisor_init_arg({integer, _, Value}) -> Value;
generate_supervisor_init_arg({string, _, Value}) -> Value;
generate_supervisor_init_arg({atom, _, Value}) -> Value;
generate_supervisor_init_arg({tuple, _, Elements}) ->
    L = [generate_supervisor_init_arg(Element) || Element <- Elements],
    Tuple0 = generate_tuple(length(L)),
    {Tuple, _} = lists:foldl(fun(E, {T0, Index}) ->
                                T1 = erlang:setelement(Index, T0, E),
                                {T1, Index + 1}
                             end, {Tuple0, 1}, L),
    Tuple;
generate_supervisor_init_arg(_) -> undefined.


generate_tuple(1) -> {undefined};
generate_tuple(2) -> {undefined, undefined};
generate_tuple(3) -> {undefined, undefined, undefined};
generate_tuple(4) -> {undefined, undefined, undefined, undefined};
generate_tuple(5) -> {undefined, undefined, undefined, undefined, undefined};
generate_tuple(6) -> {undefined, undefined, undefined, undefined,
                      undefined, undefined};
generate_tuple(7) -> {undefined, undefined, undefined, undefined,
                      undefined, undefined, undefined};
generate_tuple(8) -> {undefined, undefined, undefined, undefined,
                      undefined, undefined, undefined, undefined}.

%%------------------------------------------------------------------------------
%%
%% Add pre and post instructions to the instuctions created by appup generate.
%% These instructions must be stored in the .appup.pre.src and .appup.post.src
%% files in the src folders of the given application.
%%
%% If one of these files are missing or the version patterns specified in
%% these files don't match the current old and new versions stored in the
%% .appup file the corresponding part will be empty.
%%
%% Example:
%%
%% Generated relapp.appup
%% %% appup generated for relapp by rebar3_appup_plugin (2018/01/10 14:35:19)
%% {"1.0.34",
%%   [{ "1.0.33",
%%     [{apply,{io,format,["Upgrading is in progress..."]}}]}],
%%   [{ "1.0.33",
%%     [{apply,{io,format,["Downgrading is in progress..."]}}]}],
%% }.
%%
%% relapp.appup.pre.src:
%%
%% {"1.0.34",
%%   [{"1.*",
%%      [{apply, {io, format, ["Upgrading started from 1.* to 1.0.34"]}}]},
%%    {"1.0.33",
%%      [{apply, {io, format, ["Upgrading started from 1.0.33 to 1.0.34"]}}]}],
%%   [{".*",
%%     [{apply, {io, format, ["Downgrading started from 1.0.34 to .*"]}}]},
%%    {"1.0.33",
%%     [{apply, {io, format, ["Downgrading started from 1.0.34 to 1.0.33"]}}]}]
%% }.
%%
%% relapp.appup.post.src:
%%
%% {"1.0.34",
%%   [{"1.*",
%%      [{apply, {io, format, ["Upgrading finished from 1.* to 1.0.34"]}}]},
%%    {"1.0.33",
%%      [{apply, {io, format, ["Upgrading finished from 1.0.33 to 1.0.34"]}}]}],
%%   [{".*",
%%      [{apply, {io, format, ["Downgrading finished from 1.0.034 to .*"]}}]},
%%    {"1.0.33",
%%      [{apply, {io, format, ["Downgrading finished from 1.0.34 to 1.0.33"]}}]}]
%% }.
%%
%% The final relapp.appup file after merging the pre and post contents:
%%
%% %% appup generated for relapp by rebar3_appup_plugin (2018/01/10 14:35:19)
%% {"1.0.34",
%%   [{"1.0.33",
%%     [{apply,{io,format,["Upgrading started from 1.* to 1.0.34"]}},
%%      {apply,{io,format,["Upgrading started from 1.0.33 to 1.0.34"]}},
%%      {apply,{io,format,["Upgrading is in progress..."]}},
%%      {apply,{io,format,["Upgrading finished from 1.* to 1.0.34"]}},
%%      {apply,{io,format,["Upgrading finished from 1.0.33 to 1.0.34"]}}] }],
%%   [{"1.0.33",
%%     [{apply,{io,format,["Downgrading started from 1.0.34 to .*"]}},
%%      {apply,{io,format,["Downgrading started from 1.0.34 to 1.0.33"]}},
%%      {apply,{io,format,["Downgrading is in progress..."]}},
%%      {apply,{io,format,["Downgrading finished from 1.0.34 to .*"]}},
%%      {apply,{io,format,["Downgrading finished from 1.0.34 to 1.0.33"]}}] }]
%% }.
%%
%%------------------------------------------------------------------------------
-spec merge_instructions(string(), AppupFiles, UpgradeInstructions, DowngradeInstructions,
                         OldVer, NewVer, AppDirs) -> Res when
      AppupFiles :: [] | [string()],
      UpgradeInstructions :: list(tuple()),
      DowngradeInstructions :: list(tuple()),
      OldVer :: string(),
      NewVer :: string(),
      AppDirs :: #{atom() => string()},
      Res :: {list(tuple()), list(tuple())}.
merge_instructions(_App, [] = _AppupFiles, UpgradeInstructions, DowngradeInstructions,
                   _OldVer, _NewVer, _AppDirs) ->
    {UpgradeInstructions, DowngradeInstructions};
merge_instructions(App, [_AppUpFile], UpgradeInstructions, DowngradeInstructions,
                   OldVer, NewVer, AppDirs) ->
    {AppupPrePath, AppupPostPath} =
        case maps:find(App, AppDirs) of
            {ok, #{dir := AppDir}} ->
                {get_file_if_exists(filename:join([AppDir, "src", atom_to_list(App) ++ ".appup.pre.src"])),
                 get_file_if_exists(filename:join([AppDir, "src", atom_to_list(App) ++ ".appup.post.src"]))};
            error ->
                {undefined, undefined}
        end,
    rebar_api:debug(".appup.pre.src path: ~s", [AppupPrePath]),
    rebar_api:debug("appup.post.src path: ~s", [AppupPostPath]),
    PreContents = read_pre_post_contents(AppupPrePath),
    PostContents = read_pre_post_contents(AppupPostPath),
    rebar_api:debug(".appup.pre.src contents: ~p", [PreContents]),
    rebar_api:debug(".appup.post.src contents: ~p", [PostContents]),
    merge_instructions_0(PreContents, PostContents, OldVer, NewVer, UpgradeInstructions, DowngradeInstructions).

-spec merge_instructions_0(PreContents, PostContents, OldVer, NewVer,
                          UpgradeInstructions, DowngradeInstructions) -> Res when
      PreContents :: undefined | {string(), list(), list()},
      PostContents :: undefined | {string(), list(), list()},
      OldVer :: string(),
      NewVer :: string(),
      UpgradeInstructions :: list(tuple()),
      DowngradeInstructions :: list(tuple()),
      Res :: {list(tuple()), list(tuple())}.
merge_instructions_0(PreContents, PostContents, OldVer, NewVer,
                    UpgradeInstructions, DowngradeInstructions) ->
    {merge_pre_post_instructions(PreContents, PostContents, upgrade, OldVer,
                                 NewVer, UpgradeInstructions),
     merge_pre_post_instructions(PreContents, PostContents, downgrade, OldVer,
                                 NewVer, DowngradeInstructions)}.

-spec merge_pre_post_instructions(PreContents, PostContents, Direction, OldVer,
                                  NewVer, Instructions) -> Res when
      PreContents :: undefined | {string(), list(), list()},
      PostContents :: undefined | {string(), list(), list()},
      Direction :: upgrade | downgrade,
      OldVer :: string(),
      NewVer :: string(),
      Instructions :: list(tuple()),
      Res :: list(tuple()).
merge_pre_post_instructions(PreContents, PostContents, Direction, OldVer,
                            NewVer, Instructions) ->
    PreInstructions = expand_instructions(PreContents, Direction, OldVer, NewVer),
    PostInstructions = expand_instructions(PostContents, Direction, OldVer, NewVer),
    RemovDuplicatedInstructions = remove_duplicated_instructions(PreInstructions ++ PostInstructions, Instructions),
    PreInstructions ++ RemovDuplicatedInstructions ++ PostInstructions.
    %% expand_instructions(PreContents, Direction, OldVer, NewVer) ++
    %% Instructions ++
    %% expand_instructions(PostContents, Direction, OldVer, NewVer).

remove_duplicated_instructions(TargetInstruction, Instructions) ->
    case lists:keyfind(restart_application, 1, TargetInstruction) of
        false ->
            lists:reverse(
              lists:foldl(
                fun({update, Name, {advanced, []}, _PrePurge, _PostPurge, _Deps} = Update, Acc) ->
                        case lists:keymember(update, 1, TargetInstruction) and lists:keymember(Name, 2, TargetInstruction) of
                            true ->
                                Acc;
                            false ->
                                [Update|Acc]
                        end;
                   (Update, Acc) ->
                        [Update|Acc]
                end, [], Instructions));
        _RestartApp ->
            []
    end.

-spec read_pre_post_contents(Path) -> Res when
      Path :: undefined | string(),
      Res :: undefined | tuple().
read_pre_post_contents(undefined) ->
    undefined;
read_pre_post_contents(Path) ->
    case file:consult(Path) of
         {ok, [Contents]} ->
            Contents;
        {error, Reason} ->
            rebar_api:error("consult file ~s failed ~p", [Reason]),
            erlang:exit({consult_file_failed, Path, Reason})
    end.

-spec expand_instructions(ExtFileContents, Direction, OldVer, NewVer) ->
    Res when
      ExtFileContents :: undefined | {string(), list(), list()},
      Direction :: upgrade | downgrade,
      OldVer :: string(),
      NewVer :: string(),
      Res :: list(tuple()).
expand_instructions(undefined, _Direction, _OldVer, _NewVer) ->
    [];
expand_instructions({VersionPattern, UpInsts, DownInsts}, Direction, OldVer,
                    NewVer) ->
    case matching_versions(VersionPattern, NewVer) of
        true ->
            Instructions = case Direction of
                               upgrade -> UpInsts;
                               downgrade -> DownInsts
                           end,
            expand_instructions(Instructions, OldVer, []);
        false ->
            []
    end.

%%------------------------------------------------------------------------------
%% Check if pattern in the first parameter matches the given version.
%% matching_versions("1.*", "1.0.34") -> true
%% matching_versions(".*", "1.0.34") -> true
%%------------------------------------------------------------------------------
-spec matching_versions(Pattern, Version) -> Res when
      Pattern :: string(),
      Version :: string(),
      Res :: boolean().
matching_versions(Pattern, Version) ->
    PatternParts = string_compat:tokens(Pattern, "."),
    PatternParts1 = expand_pattern_parts(PatternParts, []),
    VersionParts = string_compat:tokens(Version, "."),
    Res = is_matching_versions(PatternParts1, VersionParts),
    rebar_api:debug("Checking if pattern '~s' matches version '~s': ~p",
                    [Pattern, Version, Res]),
    Res.

is_matching_versions([], _) ->
    true;
is_matching_versions(["*" | PatternParts], [_ | VersionParts]) ->
    is_matching_versions(PatternParts, VersionParts);
is_matching_versions([PatternPart | PatternTail], [VersionPart | VersionTail])
  when PatternPart =:= VersionPart ->
    is_matching_versions(PatternTail, VersionTail);
is_matching_versions(_PatternParts, _VersionParts) ->
    false.

-spec expand_pattern_parts(Parts, Acc) -> Res when
      Parts :: list(string()),
      Acc :: list(string()),
      Res :: list(string()).
expand_pattern_parts([], Acc) ->
    lists:reverse(Acc);
expand_pattern_parts([P | T], Acc) when P =:= "*"; P =:= "" ->
    expand_pattern_parts(T, ["*" | Acc]);
expand_pattern_parts([P | T], Acc) ->
    expand_pattern_parts(T, [P | Acc]).

-spec expand_instructions(Instructions, Version, Acc) -> Res when
      Instructions :: list({string(), list(tuple())}),
      Version :: string(),
      Acc :: list(tuple()),
      Res :: list(tuple()).
expand_instructions([], _OldVersion, Acc) ->
    Acc;
expand_instructions([{Pattern, Insts} | T], OldVersion, Acc0) ->
    Acc = case matching_versions(Pattern, OldVersion) of
              true ->
                  Acc0 ++ Insts;
              false ->
                  Acc0
          end,
    expand_instructions(T, OldVersion, Acc).

get_file_if_exists(File) ->
    case filelib:is_regular(File) of
        true ->
            File;
        false ->
            undefined
    end.
