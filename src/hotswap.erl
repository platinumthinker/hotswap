-module(hotswap).
-mode(compile).

-export([
         main/1
        ]).

main([OldRel, NewRel]) ->
    {RelName, OldVsn, Erts, OldApps} = get_rel_info(OldRel),
    {RelName, NewVsn, Erts, NewApps} = get_rel_info(NewRel),

    OldRoot = filename:dirname(filename:dirname(filename:dirname(filename:absname(OldRel)))),
    NewRoot = filename:dirname(filename:dirname(filename:dirname(filename:absname(NewRel)))),

    io:format("OldRoot: ~p~nNewRoot: ~p~n", [OldRoot, NewRoot]),

    AppUpFiles = find_files(filename:join(NewRoot, "lib"), "^[^._].*.appup$"),
    NewAppUpFiles = lists:zip([list_to_atom(filename:basename(AppName, ".appup"))
                               || AppName <- AppUpFiles], AppUpFiles),

    io:format("Generate release ~p vsn ~s from ~s~n", [RelName, NewVsn, OldVsn]),
    AddedApps = apps_diff(NewApps, OldApps),
    io:format("Added apps: ~p~n", [AddedApps]),
    RemovedApps = apps_diff(OldApps, NewApps),
    io:format("Removed apps: ~p~n", [RemovedApps]),

    PossiblyUpgraded = proplists:get_keys(NewApps),

    UpgradedApps = [upgraded_app(AppName,
                                 proplists:get_value(AppName, OldApps),
                                 proplists:get_value(AppName, NewApps),
                                 proplists:get_value(AppName, NewAppUpFiles)
                                )
                    || AppName <- PossiblyUpgraded],

    Upgraded = lists:dropwhile(fun(Elem) ->
                                       Elem == false
                               end, lists:sort(UpgradedApps)),

    io:format("Upgraded: ~p~n", [Upgraded]),

    generate_appup(Upgraded, NewRoot, OldRoot),
    generate_relup(NewVsn, NewRel, OldRel, NewRoot, OldRoot),
    NewRootRel = filename:dirname(filename:dirname(filename:dirname(NewRel))),
    LibPath = filename:join([NewRootRel, lib, "*", ebin]),
    {ok, 4385} = file:copy("install_upgrade.escript",
                           filename:join([NewRootRel, "bin",
                                          "install_upgrade.escript"])),
    io:format("Make tar ~s.tar.gz~n", [filename:rootname(NewRel)]),
    ok = systools:make_tar(filename:rootname(NewRel), [{path, [LibPath]}]),
    ok;
main(["help"]) ->
    io:format("Usage: ~n"),
    io:format("     hotswap OldRelFile NewRelFile"),
    ok;
main(Other) ->
    io:format("Command ~p understood~n", [Other]),
    main(["help"]).

get_rel_info(Rel) ->
    {ok, [{release, {RelName, RelVsn}, {erts, Erts_VSN}, Apps}]} = file:consult(Rel),
    {RelName, RelVsn, Erts_VSN, Apps}.

apps_diff(List1, List2) ->
    List3 = lists:umerge(lists:sort(proplists:get_keys(List1)),
                         lists:sort(proplists:get_keys(List2))),
    List3 -- proplists:get_keys(List2).

upgraded_app(AppName, OldAppVer, NewAppVer, undefined) when OldAppVer /= NewAppVer ->
    {AppName, {OldAppVer, NewAppVer}};
upgraded_app(AppName, OldAppVer, NewAppVer, AppUp) when OldAppVer /= NewAppVer ->
    {ok, AppUpList} = file:consult(AppUp),
    case get_value(NewAppVer, AppUpList) of
        undefined ->
            io:format("Appup file with other version ~s. Ignore.~n", [AppName]),
            {AppName, {OldAppVer, NewAppVer}};
        {UpInstr, DownInstr} ->
            %% NOTE: Add regexp (for example <<"2\\.16(\\.[0-9]+)*">>)
            case {proplists:get_value(OldAppVer, UpInstr),
                  proplists:get_value(OldAppVer, DownInstr)} of
                {undefined, undefined} ->
                    io:format("Appup file with other version ~s. Ignore.~n",
                              [AppName]),
                    {AppName, {OldAppVer, NewAppVer}};
                {A, B} when A /= undefined andalso B /= undefined ->
                    io:format("User appup file in app ~p~n", [AppName]),
                    false;
                {_, _} ->
                    io:format("Incorrect appup file ~s~n", [AppUp]),
                    throw({error, bad_appup, AppUp})
            end
    end;
upgraded_app(_, _, _, _) ->
    false.

find_files(Dir, Regex) ->
    filelib:fold_files(Dir, Regex, true, fun(F, Acc) -> [F | Acc] end, []).

get_value(VSN, [{VSN, UpInstr, DownInstr} | _Tail]) ->
    {UpInstr, DownInstr};
get_value(VSN, [{_, _, _} | Tail]) ->
    get_value(VSN, Tail);
get_value(_, []) ->
    undefined.


generate_instruction(added, File) ->
    Name = list_to_atom(file_to_name(File)),
    {add_module, Name};
generate_instruction(deleted, File) ->
    Name = list_to_atom(file_to_name(File)),
    {delete_module, Name}.

generate_instruction(changed, ModDeps, {File, _}) ->
    {ok, {Name, List}} = beam_lib:chunks(File, [attributes, exports]),
    Behavior = get_behavior(List),
    CodeChange = is_code_change(List),
    Deps = proplists:get_value(Name, ModDeps, []),
    generate_instruction_advanced(Name, Behavior, CodeChange, Deps).

generate_instruction_advanced(Name, undefined, undefined, Deps) ->
    %% Not a behavior or code change, assume purely functional
    {load_module, Name, Deps};
generate_instruction_advanced(Name, [supervisor], _, _) ->
    %% Supervisor
    {update, Name, supervisor};
generate_instruction_advanced(Name, _, code_change, Deps) ->
    %% Includes code_change export
    {update, Name, {advanced, []}, Deps};
generate_instruction_advanced(Name, _, _, Deps) ->
    %% Anything else
    {load_module, Name, Deps}.

get_behavior(List) ->
    Attributes = proplists:get_value(attributes, List),
    case proplists:get_value(behavior, Attributes) of
        undefined -> proplists:get_value(behaviour, Attributes);
        Else -> Else
    end.

is_code_change(List) ->
    Exports = proplists:get_value(exports, List),
    case proplists:is_defined(code_change, Exports) of
        true ->
            code_change;
        false ->
            undefined
    end.

file_to_name(File) ->
    filename:rootname(filename:basename(File)).

generate_appup([{App, {OldVer, NewVer}} | Tail], NewRoot, OldRoot) ->
    AppStr = erlang:atom_to_list(App) ++ "-",
    NewDir = filename:join([NewRoot, "lib", AppStr ++ NewVer, "ebin"]),
    OldDir = filename:join([OldRoot, "lib", AppStr ++ OldVer, "ebin"]),
    {AddFiles, DelFiles, ChangeFiles} = beam_lib:cmp_dirs(NewDir, OldDir),

    ModDeps = [],
    ChangeNames = [list_to_atom(file_to_name(F)) || {F, _} <- ChangeFiles],
    ModDeps1 = [{N, [M1 || M1 <- M, lists:member(M1, ChangeNames)]}
                || {N, M} <- ModDeps],

    Added = [generate_instruction(added, File) || File <- AddFiles],
    Deleted = [generate_instruction(deleted, File) || File <- DelFiles],
    Changed = [generate_instruction(changed, ModDeps1, File)
               || File <- ChangeFiles],
    Inst = lists:append([Added, Deleted, Changed]),

    AppUpFile = filename:join([NewDir, atom_to_list(App) ++ ".appup"]),

    ok = file:write_file(AppUpFile,
                         io_lib:fwrite("%% automatic generation for ~p~n"
                                       "{~p, [{~p, ~p}], [{~p, []}]}.~n",
                                       [App, NewVer, OldVer, Inst, OldVer])),
    generate_appup(Tail, NewRoot, OldRoot);
generate_appup([], _, _) -> ok.


generate_relup(NewVsn, NewRelFile, OldRelFile, NewRoot, OldRoot) ->
    Options = [
               {outdir, filename:join([NewRoot, "releases", NewVsn])},
               {path, [
                       filename:join([NewRoot, "lib", "*", "ebin"]),
                       filename:join([OldRoot, "lib", "*", "ebin"])
                      ]},
               warnings_as_errors
               ],
    NewRel = string:left(NewRelFile, string:len(NewRelFile) - 4),
    OldRel = string:left(OldRelFile, string:len(OldRelFile) - 4),
    io:format("Make relup ~s from ~s~n", [NewRel, OldRel]),
    ok = systools:make_relup(NewRel, [OldRel], [OldRel], Options),
    ok.
