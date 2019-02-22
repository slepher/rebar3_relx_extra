%% -*- erlang-indent-level: 4; indent-tabs-mode: nil; fill-column: 80 -*-
%%% Copyright 2012 Erlware, LLC. All Rights Reserved.
%%%
%%% This file is provided to you under the Apache License,
%%% Version 2.0 (the "License"); you may not use this file
%%% except in compliance with the License.  You may obtain
%%% a copy of the License at
%%%
%%%   http://www.apache.org/licenses/LICENSE-2.0
%%%
%%% Unless required by applicable law or agreed to in writing,
%%% software distributed under the License is distributed on an
%%% "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
%%% KIND, either express or implied.  See the License for the
%%% specific language governing permissions and limitations
%%% under the License.
%%%---------------------------------------------------------------------------
%%% @author Eric Merritt <ericbmerritt@gmail.com>
%%% @copyright (C) 2012 Erlware, LLC.
%%%
%%% @doc Given a complete built release this provider assembles that release
%%% into a release directory.
-module(rlx_release_bin).

-export([write_bin_file/4]).

%%============================================================================
%% API
%%============================================================================
write_bin_file(State, Release, Erts, OutputDir) ->
    RelName = erlang:atom_to_list(rlx_release:name(Release)),
    RelVsn = rlx_release:vsn(Release),
    BinDir = filename:join([OutputDir, "bin"]),
    ok = ec_file:mkdir_p(BinDir),
    VsnRel = filename:join(BinDir, rlx_release:canonical_name(Release)),
    BareRel = filename:join(BinDir, RelName),
    ErlOpts = rlx_state:get(State, erl_opts, ""),
    {OsFamily, _OsName} = rlx_util:os_type(State),
    Hooks = expand_hooks(BinDir,
                         rlx_state:get(State,
                                       extended_start_script_hooks,
                                       []),
                         State),
    Extensions = rlx_state:get(State,
                               extended_start_script_extensions,
                               []),
    StartFile = extended_bin_file_contents(OsFamily, RelName, RelVsn,
                                           Erts, ErlOpts,
                                           Hooks, Extensions),
    %% We generate the start script by default, unless the user
    %% tells us not too
    case rlx_state:get(State, generate_start_script, true) of
        false ->
            ok;
        _ ->
            VsnRelStartFile = case OsFamily of
                unix -> VsnRel;
                win32 -> rlx_string:concat(VsnRel, ".cmd")
            end,
            ok = file:write_file(VsnRelStartFile, StartFile),
            ok = file:change_mode(VsnRelStartFile, 8#755),
            BareRelStartFile = case OsFamily of
                unix -> BareRel;
                win32 -> rlx_string:concat(BareRel, ".cmd")
            end,
            ok = file:write_file(BareRelStartFile, StartFile),
            ok = file:change_mode(BareRelStartFile, 8#755)
    end.

%%%===================================================================
%%% Internal Functions
%%%===================================================================
expand_hooks(_Bindir, [], _State) -> [];
expand_hooks(BinDir, Hooks, _State) ->
    expand_hooks(BinDir, Hooks, [], _State).

expand_hooks(_BinDir, [], Acc, _State) -> Acc;
expand_hooks(BinDir, [{Phase, Hooks0} | Rest], Acc, State) ->
    %% filter and expand hooks to their respective shell scripts
    Hooks =
        lists:foldl(
            fun(Hook, Acc0) ->
                case validate_hook(Phase, Hook) of
                    true ->
                        %% all hooks are relative to the bin dir
                        HookScriptFilename = filename:join([BinDir,
                                                            hook_filename(Hook)]),
                        %% write the hook script file to it's proper location
                        ok = render_hook(hook_template(Hook), HookScriptFilename, State),
                        %% and return the invocation that's to be templated in the
                        %% extended script
                        Acc0 ++ [hook_invocation(Hook)];
                    false ->
                        ec_cmd_log:error(
                            rlx_state:log(State),
                            io_lib:format("~p hook is not allowed in the ~p phase, ignoring it", [Hook, Phase])
                        ),

                        Acc0
                end
            end, [], Hooks0),
    expand_hooks(BinDir, Rest, Acc ++ [{Phase, Hooks}], State).

%% the pid script hook is only allowed in the
%% post_start phase
%% with args
validate_hook(post_start, {pid, _}) -> true;
%% and without args
validate_hook(post_start, pid) -> true;
%% same for wait_for_vm_start, wait_for_process script
validate_hook(post_start, wait_for_vm_start) -> true;
validate_hook(post_start, {wait_for_process, _}) -> true;
%% custom hooks are allowed in all phases
validate_hook(_Phase, {custom, _}) -> true;
%% as well as status hooks
validate_hook(status, _) -> true;
%% deny all others
validate_hook(_, _) -> false.

hook_filename({custom, CustomScript}) -> CustomScript;
hook_filename(pid) -> "hooks/builtin/pid";
hook_filename({pid, _}) -> "hooks/builtin/pid";
hook_filename(wait_for_vm_start) -> "hooks/builtin/wait_for_vm_start";
hook_filename({wait_for_process, _}) -> "hooks/builtin/wait_for_process";
hook_filename(builtin_status) -> "hooks/builtin/status".

hook_invocation({custom, CustomScript}) -> CustomScript;
%% the pid builtin hook with no arguments writes to pid file
%% at /var/run/{{ rel_name }}.pid
hook_invocation(pid) -> rlx_string:join(["hooks/builtin/pid",
                                     "/var/run/$REL_NAME.pid"], "|");
hook_invocation({pid, PidFile}) -> rlx_string:join(["hooks/builtin/pid",
                                                PidFile], "|");
hook_invocation(wait_for_vm_start) -> "hooks/builtin/wait_for_vm_start";
hook_invocation({wait_for_process, Name}) ->
    %% wait_for_process takes an atom as argument
    %% which is the process name to wait for
    rlx_string:join(["hooks/builtin/wait_for_process",
                 atom_to_list(Name)], "|");
hook_invocation(builtin_status) -> "hooks/builtin/status".

hook_template({custom, _}) -> custom;
hook_template(pid) -> builtin_hook_pid;
hook_template({pid, _}) -> builtin_hook_pid;
hook_template(wait_for_vm_start) -> builtin_hook_wait_for_vm_start;
hook_template({wait_for_process, _}) -> builtin_hook_wait_for_process;
hook_template(builtin_status) -> builtin_hook_status.

%% custom hooks are not rendered, they should
%% be copied by the release overlays
render_hook(custom, _, _) -> ok;
render_hook(TemplateName, Script, State) ->
    ec_cmd_log:info(
        rlx_state:log(State),
        "rendering ~p hook to ~p~n",
        [TemplateName, Script]
    ),

    Template = render(TemplateName),
    ok = filelib:ensure_dir(Script),
    _ = ec_file:remove(Script),
    ok = file:write_file(Script, Template),
    ok = file:change_mode(Script, 8#755).

extended_bin_file_contents(OsFamily, RelName, RelVsn, ErtsVsn, ErlOpts, Hooks, Extensions) ->
    Template = case OsFamily of
        unix -> extended_bin;
        win32 -> extended_bin_windows
    end,
    %% turn all the hook lists into space separated strings
    PreStartHooks = rlx_string:join(proplists:get_value(pre_start, Hooks, []), " "),
    PostStartHooks = rlx_string:join(proplists:get_value(post_start, Hooks, []), " "),
    PreStopHooks = rlx_string:join(proplists:get_value(pre_stop, Hooks, []), " "),
    PostStopHooks = rlx_string:join(proplists:get_value(post_stop, Hooks, []), " "),
    PreInstallUpgradeHooks = rlx_string:join(proplists:get_value(pre_install_upgrade,
                                                Hooks, []), " "),
    PostInstallUpgradeHooks = rlx_string:join(proplists:get_value(post_install_upgrade,
                                                 Hooks, []), " "),
    StatusHook = rlx_string:join(proplists:get_value(status, Hooks, []), " "),
    {ExtensionsList1, ExtensionDeclarations1} =
        lists:foldl(fun({Name, Script},
                        {ExtensionsList0, ExtensionDeclarations0}) ->
                            ExtensionDeclaration = atom_to_list(Name) ++
                                                   "_extension=\"" ++
                                                   Script ++ "\"",
                            {ExtensionsList0 ++ [atom_to_list(Name)],
                             ExtensionDeclarations0 ++ [ExtensionDeclaration]}
                    end, {[], []}, Extensions),
    % pipe separated string of extensions, to show on the start script usage
    % (eg. foo|bar)
    ExtensionsList = rlx_string:join(ExtensionsList1 ++ ["undefined"], "|"),
    % command separated string of extension script declarations
    % (eg. foo_extension="path/to/foo_script")
    ExtensionDeclarations = rlx_string:join(ExtensionDeclarations1, ";"),
    render(Template, [{rel_name, RelName}, {rel_vsn, RelVsn},
                      {erts_vsn, ErtsVsn}, {erl_opts, ErlOpts},
                      {pre_start_hooks, PreStartHooks},
                      {post_start_hooks, PostStartHooks},
                      {pre_stop_hooks, PreStopHooks},
                      {post_stop_hooks, PostStopHooks},
                      {pre_install_upgrade_hooks, PreInstallUpgradeHooks},
                      {post_install_upgrade_hooks, PostInstallUpgradeHooks},
                      {status_hook, StatusHook},
                      {extensions, ExtensionsList},
                      {extension_declarations, ExtensionDeclarations}]).

render(Template) ->
    render(Template, []).

render(extended_bin, Data) ->
    TemplateFile = filename:join([code:priv_dir(rebar3_relx_extra), "templates", "extended_bin"]),
    {ok, Bin} = file:read_file(TemplateFile),
    {ok, Content} = rlx_util:render(Bin, Data),
    Content;

render(Template, Data) ->
    Files = rlx_util:template_files(),
    Tpl = rlx_util:load_file(Files, escript, atom_to_list(Template)),
    {ok, Content} = rlx_util:render(Tpl, Data),
    Content.
