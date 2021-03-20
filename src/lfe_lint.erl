%% Copyright (c) 2008-2021 Robert Virding
%%
%% Licensed under the Apache License, Version 2.0 (the "License");
%% you may not use this file except in compliance with the License.
%% You may obtain a copy of the License at
%%
%%     http://www.apache.org/licenses/LICENSE-2.0
%%
%% Unless required by applicable law or agreed to in writing, software
%% distributed under the License is distributed on an "AS IS" BASIS,
%% WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
%% See the License for the specific language governing permissions and
%% limitations under the License.

%% File    : lfe_lint.erl
%% Author  : Robert Virding
%% Purpose : Lisp Flavoured Erlang syntax checker.

%%% We get a lot help here from the Erlang linter as our code is
%%% passed on into it when the erlng code is compiled. This means that
%%% if we miss anything it will catch it. How much do we really needt
%%% to do here?

%%% In a fun argument where when matching a binary we import the size
%%% of bitseg as a variable from the environment not just from earlier
%%% segments. No other argument variables are imported.

-module(lfe_lint).

-export([module/1,module/2,form/1,expr/1,expr/2,
         pattern/1,pattern/2,format_error/1]).

%% -compile(export_all).

-import(lists, [member/2,sort/1,all/2,foldl/3,foldr/3,foreach/2,mapfoldl/3]).
-import(ordsets, [add_element/2,from_list/1,is_element/2,
                  union/1,union/2,intersection/2,subtract/2]).

-include("lfe_comp.hrl").
-include("lfe.hrl").

-record(lfe_lint, {module=[],                   %Module name
                   mline=0,                     %Module definition line
                   exps=orddict:new(),          %Exported functions
                   imps=orddict:new(),          %Imported functions
                   funcs=[],                    %Defined functions
                   types=[],                    %Known types
                   texps=orddict:new(),         %Exported types
                   specs=[],                    %Known func specs
                   recs=[],                     %Known record defs
                   env=[],                      %Top-level environment
                   func=[],                     %Current function
                   file="no file",              %File name
                   opts=[],                     %Compiler options
                   errors=[],                   %Errors
                   warnings=[]                  %Warnings
                  }).

%% Errors.
%% Module definition.
format_error({bad_module,D}) ->
    %% This can handle both atom and string error value.
    lfe_io:format1(<<"bad ~s in module definition">>, [D]);
format_error({bad_attribute,A}) ->
    lfe_io:format1(<<"bad ~w attribute">>, [A]);
format_error({bad_meta,M}) ->
    lfe_io:format1(<<"bad ~w metadata">>, [M]);
%% Forms and code.
format_error({bad_body,Form}) ->
    lfe_io:format1(<<"bad body in ~w">>, [Form]);
format_error(bad_guard) -> "bad guard";
format_error(bad_args) -> "bad argument list";
format_error(bad_gargs) -> "bad guard argument list";
format_error(bad_alias) -> "bad pattern alias";
format_error(bad_arity) -> "head arity mismatch";
format_error({bad_form,Form}) ->
    lfe_io:format1(<<"bad ~w form">>, [Form]);
format_error({bad_guard_form,Form}) ->
    lfe_io:format1(<<"bad ~w guard form">>, [Form]);
format_error({bad_pattern,Pat}) ->
    lfe_io:format1(<<"bad ~w pattern">>, [Pat]);
format_error({unbound_symb,S}) ->
    lfe_io:format1(<<"symbol ~w is unbound">>, [S]);
format_error({undefined_function,{F,A}}) ->
    lfe_io:format1("function ~w/~w undefined", [F,A]);
format_error({multi_var,S}) ->
    lfe_io:format1("variable ~w multiply defined", [S]);
%% Functions.
format_error({redefine_function,F}) ->
    lfe_io:format1("function ~w already defined", [F]);
format_error({bad_fdef,F}) ->
    lfe_io:format1("bad definition of function ~w", [F]);
format_error({illegal_literal,Lit}) ->
    lfe_io:format1(<<"illegal literal value ~w">>, [Lit]);
format_error({illegal_pattern,Pat}) ->
    lfe_io:format1(<<"illegal pattern ~w">>, [Pat]);
format_error(illegal_guard) -> <<"illegal guard expression">>;
format_error({illegal_mapkey,Key}) ->
    lfe_io:format1(<<"illegal map key ~w">>, [Key]);
format_error(illegal_bitseg) -> "illegal bit segment";
format_error(illegal_bitsize) -> "illegal bit size";
format_error({deprecated,What}) ->
    lfe_io:format1("~s is deprecated", [What]);
format_error(unknown_form) -> "unknown form";
%% Try-catches.
format_error({illegal_stacktrace,S}) ->
    lfe_io:format1(<<"stacktrace ~w must be unbound variable">>, [S]);
format_error({illegal_exception,E}) ->
    lfe_io:format1(<<"illegal exception ~w">>, [E]);
%% Records.
format_error({bad_record,Name}) ->
    lfe_io:format1(<<"bad definition of record ~w">>, [Name]);
format_error({bad_field,Name,Field}) ->
    lfe_io:format1(<<"bad field ~w in record ~w">>, [Field,Name]);
format_error({redefine_record,Name}) ->
    lfe_io:format1(<<"record ~w already defined">>, [Name]);
format_error({missing_field_value,Name,Field}) ->
    lfe_io:format1(<<"missing value to field ~w in record ~w">>,[Field,Name]);
%% These are also used in lfe_eval.
format_error({undefined_record,Name}) ->
    lfe_io:format1(<<"record ~w undefined">>, [Name]);
format_error({undefined_field,Name,Field}) ->
    lfe_io:format1(<<"field ~w undefined in record ~w">>, [Field,Name]);
%% Type and spec errors.
format_error({undefined_type,{T,A}}) ->
    lfe_io:format1("type ~w/~w undefined", [T,A]);
format_error({builtin_type,{T,A}}) ->
    lfe_io:format1("type ~w/~w is a builtin type", [T,A]);
format_error({redefine_type,{T,A}}) ->
    lfe_io:format1("type ~w/~w already defined", [T,A]);
format_error({redefine_spec,{F,A}}) ->
    lfe_io:format1("spec for ~w/~w is already defined", [F,A]);
format_error({singleton_typevar,V}) ->
    lfe_io:format1("type variable ~w is only used once", [V]);
%% Type and spec errors. These are also returned from lfe_types.
format_error({bad_type,T}) ->
    lfe_io:format1("bad ~w type definition", [T]);
format_error({type_syntax,T}) ->
    lfe_io:format1("bad ~w type", [T]);
format_error({bad_spec,S}) ->
    lfe_io:format1("bad function specification: ~w", [S]);
%% These are signaled from lfe_bits.
format_error({undefined_bittype,S}) ->
    lfe_io:format1("bit type ~w undefined", [S]);
format_error(bittype_unit) ->
    "bit unit size can only be specified together with size".

%% expr(Expr) -> {ok,[Warning]} | {error,[Error],[Warning]}.
%% expr(Expr, Env) -> {ok,[Warning]} | {error,[Error],[Warning]}.

expr(E) -> expr(E, lfe_env:new()).

expr(E, Env) ->
    St0 = #lfe_lint{},
    St1 = check_expr(E, Env, 1, St0),
    return_status(St1).

%% pattern(Pattern) -> {ok,[Warning]} | {error,[Error],[Warning]}.
%% pattern(Pattern, Env) -> {ok,[Warning]} | {error,[Error],[Warning]}.

pattern(P) -> pattern(P, lfe_env:new()).

pattern(P, Env) ->
    St0 = #lfe_lint{},
    {_,St1} = pattern(P, Env, 1, St0),
    return_status(St1).

%% form(Form) -> {ok,[Warning]} | {error,[Error],[Warning]}.
%%  Create a dummy module then test the form, a function.

form(F) ->
    module([{['define-module',dummy,[],[]],1},{F,2}]).

%% module(ModuleForms) ->
%%     {ok,ModuleName,[Warning]} | {error,[Error],[Warning]}.
%% module(ModuleForms, CompInfo) ->
%%     {ok,ModuleName,[Warning]} | {error,[Error],[Warning]}.
%%  Lint the forms in one module file.

module(Ms) -> module(Ms, #cinfo{file="nofile",opts=[]}).

module(Ms, #cinfo{file=F,opts=Os}) ->
    St0 = #lfe_lint{file=F,opts=Os},            %Initialise the lint record
    St1 = check_module(Ms, St0),
    ?DEBUG("#lfe_lint: ~s\n", [io_lib:format("~p",[St1])], Os),
    return_status(St1).

return_status(#lfe_lint{module=M,errors=[]}=St) ->
    {ok,M,St#lfe_lint.warnings};
return_status(St) ->
    {error,St#lfe_lint.errors,St#lfe_lint.warnings}.

%% check_module(ModuleForms, State) -> State.
%%  Do all the actual work checking a module.

check_module(Mfs, St0) ->
    {Fbs0,St1} = collect_module(Mfs, St0),
    %% Make an initial environment and set up state.
    {Predefs,Env0,St2} = init_state(St1),
    Fbs1 = Predefs ++ Fbs0,
    %% Now check definitions.
    {Fs,Env1,St3} = check_functions(Fbs1, Env0, St2),
    %% Save functions and environment and test exports.
    St4 = St3#lfe_lint{funcs=Fs,env=Env1},
    St5 = check_valid_exports(St4),
    check_valid_type_exports(St5).

%% collect_module(ModuleForms, State) -> {Fbs,State}.
%%  Collect valid forms and module data. Returns function bindings and
%%  puts module data into state. Flag unknown forms and define-module
%%  not first. We use lfe_proc_forms to automatically handle nested
%%  progn forms for us.

collect_module(Mfs, St) ->
    lfe_lib:proc_forms(fun collect_form/3, Mfs, St).

%% collect_form(Form, Line, State) -> {Fbs,State}.

collect_form(['define-module',Mod,Meta,Atts], L, St0) ->
    St1 = check_mod_def(Meta, Atts, L, St0#lfe_lint{module=Mod,mline=L}),
    if is_atom(Mod) ->                  %Normal module
            {[],St1};
       true ->                          %Bad module name
            {[],bad_module_error(L, name, St1)}
    end;
collect_form(_, L, #lfe_lint{module=[]}=St) ->
    %% Set module name so this only triggers once.
    {[],bad_module_error(L, name, St#lfe_lint{module='-no-module-'})};
collect_form(['extend-module',Metas,Atts], L, St) ->
    {[],check_mod_def(Metas, Atts, L, St)};
collect_form(['define-type',Type,Def], L, St) ->
    {[],check_type_def(Type, Def, L, St)};
collect_form(['define-opaque-type',Type,Def], L, St) ->
    {[],check_type_def(Type, Def, L, St)};
collect_form(['define-function-spec',Func,Specs], L, St) ->
    {[],check_func_spec(Func, Specs, L, St)};
collect_form(['define-record',Name,Fields], L, St) ->
    {[],check_record_def(Name, Fields, L, St)};
collect_form(['define-function',Func,Meta,Def], L, St) ->
    collect_function(Func, Meta, Def, L, [], St);
%% lfe_lib:proc_forms handles nested progn.
%% Ignore macro definitions and eval-when-compile forms.
collect_form(['define-macro'|_], _, St) -> {[],St};
collect_form(['eval-when-compile'|_], _, St) -> {[],St};
collect_form(_, L, St) ->
    {[],add_error(L, unknown_form, St)}.

%% check_mod_def(Metadata, Attributes, Line, State) -> State.
%%  Check a module definition, its metasdata and attributes.

check_mod_def(Metas, Atts, L, St0) ->
    St1 = check_mod_metas(Metas, L, St0),
    check_attrs(Atts, L, St1).

%% check_mod_metas(Metas, Line, State) -> State.
%%  Only allow docs and type definitions.

check_mod_metas(Ms, L, St) ->
    check_foreach(fun (M, S) -> check_mod_meta(M, L, S) end,
                  fun (S) -> bad_module_error(L, <<"meta form">>, S) end,
                  St, Ms).

check_mod_meta([doc|Docs], L, St) ->
    ?IF(is_docs_list(Docs), St, bad_meta_error(L, doc, St));
check_mod_meta([type|Tds], L, St) ->
    check_type_defs(Tds, L, St);
check_mod_meta([opaque|Tds], L, St) ->
    check_type_defs(Tds, L, St);
check_mod_meta([spec|Sps], L, St) ->
    check_func_specs(Sps, L, St);
check_mod_meta([record|Rdefs], L, St) ->
    %% deprecated_error(L, <<"module record definition">>, St);
    check_record_defs(Rdefs, L, St);
check_mod_meta(_, L, St) -> bad_module_error(L, meta, St).

%% check_attrs(Attributes, Line, State) -> State.
%%  Check the attributes of the module.

check_attrs(As, L, St) ->
    check_foreach(fun (A, S) -> check_attr(A, L, S) end,
                  fun (S) -> bad_module_error(L, <<"attribute form">>, S) end,
                  St, As).

check_attr([export,all], _, St) -> St;          %Ignore 'all' here
check_attr([export|Es], L, St) ->
    check_exports(Es, L, St);
check_attr([import|Is], L, St) ->
    check_imports(Is, L, St);
check_attr(['export-type'|Ts], L, St) ->
    check_export_types(Ts, L, St);
check_attr([doc|Docs], L, St0) ->
    St1 = deprecated_warning(L, <<"module documentation attribute">>, St0),
    check_doc_attr(Docs, L, St1);
check_attr([record|_Rds], L, St) ->
    deprecated_error(L, <<"module record definition attribute">>, St);
%% Note we don't allow type and spec as normal attributes here.
check_attr([A|Vals], L, St) ->
    %% Meta tags are not allowed in attributes.
    ?IF(is_meta_tag(A), bad_attr_error(L, A, St),
        %% Other attributes, must be list and have symbol name.
        ?IF(is_atom(A) and lfe_lib:is_proper_list(Vals),
            St, bad_attr_error(L, A, St)));
check_attr(_, L, St) -> bad_module_error(L, <<"attribute form">>, St).

is_meta_tag(doc) -> true;
is_meta_tag(spec) -> true;
is_meta_tag(Tag) -> lfe_types:is_type_decl(Tag).

check_doc_attr(Docs, L, St) ->
    ?IF(is_docs_list(Docs), St, bad_attr_error(L, doc, St)).

check_exports(Es, L, St) ->
    case is_func_list(Es) of
        {yes,Fs} ->
            Exps = add_exports(Fs, L, St#lfe_lint.exps),
            St#lfe_lint{exps=Exps};
        no -> bad_module_error(L, export, St)
    end.

check_imports(Is, L, St) ->
    check_foreach(fun (I, S) -> check_import(I, L, S) end,
                  fun (S) -> import_error(L, S) end, St, Is).

check_import([from,Mod|Fs], L, St) when is_atom(Mod) ->
    Check = fun ([F,A], Imps, S) when is_atom(F), is_integer(A) ->
                    {orddict:store({F,A}, F, Imps),S};
                (_, Imps, S) -> {Imps,bad_module_error(L, <<"import from">>, S)}
            end,
    check_import(Check, Mod, L, St, Fs);
check_import([rename,Mod|Rs], L, St) when is_atom(Mod) ->
    Check = fun ([[F,A],R], Imps, S) when is_atom(F),
                                          is_integer(A),
                                          is_atom(R) ->
                    {orddict:store({F,A}, R, Imps),S};
                (_, Imps, S) -> {Imps,bad_module_error(L, <<"import rename">>, S)}
            end,
    check_import(Check, Mod, L, St, Rs);
check_import([prefix,Mod,Pre], L, St0) when is_atom(Mod), is_atom(Pre) ->
    deprecated_error(L, <<"import prefix">>, St0);
check_import(_, L, St) -> import_error(L, St).

check_import(Check, Mod, L, St0, Fs) ->
    Imps0 = safe_fetch(Mod, St0#lfe_lint.imps, []),
    {Imps1,St1} = foldl_form(Check, import, L, Imps0, St0, Fs),
    St1#lfe_lint{imps=orddict:store(Mod, Imps1, St1#lfe_lint.imps)}.

import_error(L, St) -> bad_module_error(L, import, St).

check_export_types(Ts, L, St) ->
    case is_func_list(Ts) of
        {yes,Fs} ->
            Texps = add_exports(Fs, L, St#lfe_lint.texps),
            St#lfe_lint{texps=Texps};
        no ->
            bad_module_error(L, 'export-type', St)
    end.

is_func_list(Fs) -> is_func_list(Fs, []).

is_func_list([[F,Ar]|Fs], Funcs) when is_atom(F), is_integer(Ar), Ar >= 0 ->
    is_func_list(Fs, add_element({F,Ar}, Funcs));
is_func_list([], Funcs) -> {yes,Funcs};
is_func_list(_, _) -> no.

%% check_type_defs(TypeDefs, Line, State) -> State.
%% check_type_def(TypeDef, Line, State) -> State.
%% check_type_def(Type, Def, Line, State) -> State.
%%  Check a type definition.

check_type_defs(Tds, L, St) ->
    check_foreach(fun (Td, S) -> check_type_def(Td, L, S) end,
                  fun (S) -> bad_meta_error(L, type, S) end,
                  St, Tds).

check_type_def([Type,Def], L, St) ->
    check_type_def(Type, Def, L, St);
check_type_def(_, L, St) ->
    bad_meta_error(L, type, St).

check_type_def(Type, Def, L, St0) ->
    {Tvs0,St1} = check_type_name(Type, L, St0),
    %% case lfe_types:check_type_def(Def, St1#lfe_lint.types, Tvs0) of
    case lfe_types:check_type_def(Def, St1#lfe_lint.recs, Tvs0) of
        {ok,Tvs1} -> check_type_vars(Tvs1, L, St1);
        {error,Error,Tvs1} ->
            St2 = add_error(L, Error, St1),
            check_type_vars(Tvs1, L, St2)
    end.

check_type_name([T|Args], L, #lfe_lint{types=Kts}=St) when is_atom(T) ->
    case lfe_lib:is_symb_list(Args) of
        true ->
            Arity = length(Args),
            Kt = {T,Arity},
            Tvs = lists:foldl(fun (V, S) -> orddict:update_counter(V, 1, S) end,
                              [], Args),
            case lists:member(Kt, Kts) of
                true -> {Tvs,add_error(L, {redefine_type,{T,Arity}}, St)};
                false ->
                    case lfe_internal:is_type(T, Arity) of
                        true ->
                            {Tvs,add_error(L, {builtin_type,{T,Arity}}, St)};
                        false ->
                            {Tvs,St#lfe_lint{types=[Kt|Kts]}}
                    end
            end;
        false -> {[],bad_type_error(L, T, St)}
    end;
check_type_name(T, L, St) ->                    %Type name wrong format
    {[],bad_type_error(L, T, St)}.

%% check_type_vars(TypeVars, Line, State) -> State.
%%  Check for singleton type variables except for _ which we allow.

check_type_vars(Tvs, L, St) ->
    Check = fun (V, 1, S) when V =/= '_' ->
                    add_error(L, {singleton_typevar,V}, S);
                (_, _, S) -> S
            end,
    orddict:fold(Check, St, Tvs).

%% check_func_specs(FuncSpecs, Line, State) -> State.
%% check_func_spec(FuncSpec, Line, State) -> State.
%% check_func_spec(Func, Specs, Line, State) -> State.
%%  Check a function specification.

check_func_specs(Sps, L, St) ->
    check_foreach(fun (Sp, S) -> check_func_spec(Sp, L, S) end,
                  fun (S) -> bad_meta_error(L, spec, S) end,
                  St, Sps).

check_func_spec([Func|Specs], L, St) ->
    check_func_spec(Func, Specs, L, St);
check_func_spec(_, L, St) ->
    bad_meta_error(L, spec, St).

check_func_spec(Func, Specs, L, St0) ->
    {Ar,St1} = check_func_name(Func, L, St0),
    case lfe_types:check_func_spec_list(Specs, Ar, St1#lfe_lint.recs) of
        {ok,Tvss} -> 
            check_type_vars_list(Tvss, L, St1);
        {error,Error,Tvss} ->
            St2 = add_error(L, Error, St1),
            check_type_vars_list(Tvss, L, St2)
    end.

check_func_name([F,Ar], L, #lfe_lint{specs=Kss}=St)
  when is_atom(F), is_integer(Ar), Ar >= 0 ->
    Ks = {F,Ar},
    case lists:member(Ks, Kss) of
        true -> {Ar,add_error(L, {redefine_spec,{F,Ar}}, St)};
        false -> {Ar,St#lfe_lint{specs=[Ks|Kss]}}
    end;
check_func_name(F, L, St) ->
    {0,add_error(L, {bad_spec,F}, St)}.

check_type_vars_list(Tvss, L, St) ->
    lists:foldl(fun (Tvs, S) -> check_type_vars(Tvs, L, S) end, St, Tvss).

%% collect_function(Name, Meta, Def, Line, Fbs, State) -> {Fbs,State}.
%%  Collect function and do some basic checks.

collect_function(Name, Meta, Def, L, Fbs, St0) ->
    St1 = check_func_metas(Name, Meta, L, St0),
    {[{Name,Def,L}|Fbs],St1}.

%% check_func_metas(Name, Metas, Line, State) -> State.

check_func_metas(N, Ms, L, St) ->
    check_foreach(fun (M, S) -> check_func_meta(N, M, L, S) end,
                  fun (S) -> bad_form_error(L, 'define-function', S) end,
                  St, Ms).

check_func_meta(N, [doc|Docs], L, St) ->
    ?IF(is_docs_list(Docs), St, bad_meta_error(L, N, St));
%% Need to get arity in here.
%% check_func_meta(N, [spec|Specs], L, St0) ->
%%     case lfe_types:check_func_spec_list(Specs, Ar, St#lfe_lint.recs) of
%%         {ok,Tvss} ->
%%             check_type_vars_list(Tvss, L, St0);
%%         {error,Error,Tvss} ->
%%             St1 = add_error(L, Error, St0),
%%             check_type_vars_list(Tvss, L, St1)
%%     end;
check_func_meta(N, [M|Vals], L, St) ->
    ?IF(is_atom(M) and lfe_lib:is_proper_list(Vals),
        St, bad_meta_error(L, N, St));
check_func_meta(N, _, L, St) -> bad_meta_error(L, N, St).

%% is_docs_list(Docs) -> boolean().

is_docs_list(Docs) ->
    Fun = fun (D) -> lfe_lib:is_doc_string(D) end,
    lfe_lib:is_proper_list(Docs) andalso lists:all(Fun, Docs).

%% check_record_defs(RecordDefs, Line, State) -> State.
%% check_record_def(RecordDef, Meta, Line, State) -> State.
%% check_record_def(RecordName, Meta, Fields, Line, State) -> State.
%%  Check a record definition.

check_record_defs(Rdefs, L, St) ->
    check_foreach(fun (Rdef, S) -> check_record_def(Rdef, L, S) end,
                  fun (S) -> bad_meta_error(L, record, S) end,
                  St, Rdefs).

check_record_def([Name,Fields], L, St) ->
    check_record_def(Name, Fields, L, St);
check_record_def(_, L, St) ->
    bad_meta_error(L, record, St).

check_record_def(Name, Fds, L, #lfe_lint{recs=Recs}=St0)
  when is_atom(Name) ->
    case orddict:is_key(Name, Recs) of
        true ->
            add_error(L, {redefine_record,Name}, St0);
        false ->
            %% Insert the record with no fields yet.
            St1 = St0#lfe_lint{recs=orddict:store(Name, [], Recs)},
            check_foreach(fun (Fd, S) ->
                                  check_record_field_def(Name, Fd, L, S) end,
                          fun (S) -> bad_record_error(L, Name, S) end,
                          St1, Fds)
    end;
check_record_def(Name, _, L, St) ->
    bad_record_error(L, Name, St).

check_record_field_def(Name, [Field,D,Type], L, St0) ->
    St1 = check_record_field_def(Name, [Field,D], L, St0),
    case lfe_types:check_type_def(Type, St1#lfe_lint.recs, []) of
        {ok,Tvs} -> check_type_vars(Tvs, L, St1);
        {error,Error,Tvs} ->
            St2 = add_error(L, Error, St1),
            check_type_vars(Tvs, L, St2)
    end;
check_record_field_def(Name, [Field,_D], L, St) ->
    %% Default value checked when record is made.
    check_record_field_def(Name, Field, L, St);
check_record_field_def(Name, [Field], L, St) ->
    check_record_field_def_1(Name, Field, L, St);
check_record_field_def(Name, Field, L, St) ->
    check_record_field_def_1(Name, Field, L, St).

check_record_field_def_1(Name, Field, L,  #lfe_lint{recs=Rs}=St) ->
    if is_atom(Field) ->
            St#lfe_lint{recs=orddict:append(Name, Field, Rs)};
       true ->
            bad_field_error(L, Name, Field, St)
    end.

%% init_state(State) -> {Predefs,Env,State}.
%%  Setup the initial predefines and state. Build dummies for
%%  predefined module_info which makes it easier to later check
%%  redefines.

init_state(St) ->
    %% Add the imports.
    Env0 = foldl(fun ({M,Fs}, Env) ->
                         foldl(fun ({{F,A},R}, E) ->
                                       lfe_env:add_ibinding(M, F, A, R, E)
                               end, Env, Fs)
                 end, lfe_env:new(), St#lfe_lint.imps),
    %% Basic predefines
    Predefs0 = [{module_info,[lambda,[],?Q(dummy)],1},
                {module_info,[lambda,[x],?Q(dummy)],1}],
    Exps0 = [{module_info,0},{module_info,1}],
    {Predefs0,Env0,
     St#lfe_lint{exps=add_exports(Exps0, St#lfe_lint.mline, St#lfe_lint.exps)}}.

%% check_functions(FuncBindings, Env, State) -> {Funcs,Env,State}.
%%  Check the top-level functions definitions. These have the format
%%  as in letrec but the environment only contains explicit imports
%%  and the module info functions.

check_functions(Fbs, Env0, St0) ->
    {Fs,St1} = check_fbindings(Fbs, St0),
    %% Add to the environment.
    Env1 = foldl(fun ({F,A}, Env) -> add_fbinding(F, A, Env) end, Env0, Fs),
    %% Now check function definitions.
    St2 = foldl(fun ({_,[lambda|Lambda],L}, St) ->
                        check_lambda(Lambda, Env1, L, St);
                    ({_,['match-lambda'|Match],L}, St) ->
                        check_match_lambda(Match, Env1, L, St);
                    ({F,_,L}, St) ->            %Flag error here
                        bad_fdef_error(L, F, St)
                end, St1, Fbs),
    {Fs,Env1,St2}.

%% check_valid_exports(State) -> State.

check_valid_exports(#lfe_lint{exps=Exps,funcs=Fs}=St) ->
    Fun = fun (E, L, S) ->
                  ?IF(is_element(E, Fs), S, undefined_function_error(L, E, S))
          end,
    orddict:fold(Fun, St, Exps).

%% add_exports(More, Line, Exports) -> New.
%%  Add exports preserving line number of earliest entry.

add_exports(More, L, Exps) ->
    Fun = fun (F, Es) ->
                  orddict:update(F, fun (Old) -> Old end, L, Es)
          end,
    lists:foldl(Fun, Exps, More).

%% check_valid_type_exports(State) -> State.

check_valid_type_exports(#lfe_lint{types=Types,texps=Texps}=St) ->
    Fun = fun (E, L, S) ->
                  ?IF(lists:member(E, Types), S,
                      add_error(L, {undefined_type,E}, S))
          end,
    orddict:fold(Fun, St, Texps).

%% check_expr(Expr, Env, Line, State) -> State.
%% Check an expression.

%% Check the Core data special forms.
check_expr(?Q(Lit), Env, L, St) -> literal(Lit, Env, L, St);
check_expr([cons|[_,_]=As], Env, L, St) -> check_args(As, Env, L, St);
check_expr([car,E], Env, L, St) -> check_expr(E, Env, L, St);
check_expr([cdr,E], Env, L, St) -> check_expr(E, Env, L, St);
check_expr([list|As], Env, L, St) -> check_args(As, Env, L, St);
check_expr([tuple|As], Env, L, St) -> check_args(As, Env, L, St);
check_expr([tref|[_,_]=As], Env, L, St) -> check_args(As, Env, L, St);
check_expr([tset|[_,_,_]=As], Env, L, St) -> check_args(As, Env, L, St);
check_expr([binary|Segs], Env, L, St) -> expr_bitsegs(Segs, Env, L, St);
check_expr([map|As], Env, L, St) ->
    check_map(As, Env, L, St);
check_expr(['msiz',Map], Env, L, St) ->
    check_map_size(msiz, Map, Env, L, St);
check_expr(['mref',Map,Key], Env, L, St) ->
    check_map_get(mref, Map, Key, Env, L, St);
check_expr(['mset',Map|As], Env, L, St) ->
    check_map_set(mset, Map, As, Env, L, St);
check_expr(['mupd',Map|As], Env, L, St) ->
    check_map_update(mupd, Map, As, Env, L, St);
check_expr(['mrem',Map|Ks], Env, L, St) ->
    check_map_remove(mrem, Map, Ks, Env, L, St);
check_expr(['map-size',Map], Env, L, St) ->
    check_map_size('map-size', Map, Env, L, St);
check_expr(['map-get',Map,Key], Env, L, St) ->
    check_map_get('map-get', Map, Key, Env, L, St);
check_expr(['map-set',Map|As], Env, L, St) ->
    check_map_set('map-set', Map, As, Env, L, St);
check_expr(['map-update',Map|As], Env, L, St) ->
    check_map_update('map-update', Map, As, Env, L, St);
check_expr(['map-remove',Map|Ks], Env, L, St) ->
    check_map_remove('map-remove', Map, Ks, Env, L, St);
check_expr([function,F,Ar], Env, L, St) ->
    %% Check for the right types.
    if is_atom(F) and is_integer(Ar) and (Ar >= 0) ->
            check_func(F, Ar, Env, L, St);
       true -> bad_form_error(L, function, St)
    end;
check_expr([function,M,F,Ar], _, L, St) ->
    %% Just need the right types here.
    if is_atom(M) and is_atom(F) and is_integer(Ar) and (Ar >= 0) -> St;
       true -> bad_form_error(L, function, St)
    end;
%% Check record special forms.
check_expr(['make-record',Name|Fs], Env, L, St) ->
    check_record(Name, Fs, Env, L, St);
check_expr(['record-index',Name,F], _Env, L, St) ->
    check_record_field(Name, F, L, St);
check_expr(['record-field',E,Name,F], Env, L, St0) ->
    St1 = check_expr(E, Env, L, St0),
    check_record_field(Name, F, L, St1);
check_expr(['record-update',E,Name|Fs], Env, L, St0) ->
    St1 = check_expr(E, Env, L, St0),
    check_record(Name, Fs, Env, L, St1);
%% Special known data type operations.
check_expr(['andalso'|Es], Env, L, St) ->
    check_args(Es, Env, L, St);
check_expr(['orelse'|Es], Env, L, St) ->
    check_args(Es, Env, L, St);
%% Check the Core closure special forms.
check_expr(['lambda'|Lambda], Env, L, St) ->
    check_lambda(Lambda, Env, L, St);
check_expr(['match-lambda'|Match], Env, L, St) ->
    check_match_lambda(Match, Env, L, St);
check_expr(['let'|Let], Env, L, St) ->
    check_let(Let, Env, L, St);
check_expr(['let-function'|Flet], Env, L, St) ->
    check_let_function(Flet, Env, L, St);
check_expr(['letrec-function'|Fletrec], Env, L, St) ->
    check_letrec_function(Fletrec, Env, L, St);
check_expr(['let-macro'|_], _, L, St) ->
    %% This should never occur! Removed by macro expander.
    bad_form_error(L, 'let-macro', St);
%% Check the Core control special forms.
check_expr(['progn'|B], Env, L, St) ->
    check_body(progn, B, Env, L, St);
check_expr(['if'|B], Env, L, St) ->
    check_if(B, Env, L, St);
check_expr(['case'|B], Env, L, St) ->
    check_case(B, Env, L, St);
check_expr(['receive'|Cls], Env, L, St) ->
    check_rec_clauses(Cls, Env, L, St);
check_expr(['catch'|B], Env, L, St) ->
    check_body('catch', B, Env, L, St);
check_expr(['try'|B], Env, L, St) ->
    check_try(B, Env, L, St);
check_expr(['funcall'|As], Env, L, St) ->
    check_args(As, Env, L, St);
%% Finally the general cases.
check_expr(['call'|As], Env, L, St) ->
    check_args(As, Env, L, St);
check_expr([Fun|As], Env, L, St0) when is_atom(Fun) ->
    St1 = check_args(As, Env, L, St0),          %Check arguments first
    check_func(Fun, safe_length(As), Env, L, St1);
check_expr([_|As]=S, Env, L, St0) ->            %Test if literal string
    case lfe_lib:is_posint_list(S) of
        true -> St0;
        false ->
            %% Function here is an expression, report error and check args.
            St1 = bad_form_error(L, application, St0),
            check_args(As, Env, L, St1)
    end;
check_expr(Symb, Env, L, St) when is_atom(Symb) ->
    check_symb(Symb, Env, L, St);
check_expr(Lit, Env, L, St) ->                  %Everything else is a literal
    literal(Lit, Env, L, St).

%% check_symb(Symbol, Env, Line, State) -> State.
%%  Check if Symbol is bound.

check_symb(Symb, Env, L, St) ->
    case lfe_env:is_vbound(Symb, Env) of
        true -> St;
        false -> add_error(L, {unbound_symb,Symb}, St)
    end.

%% check_func(Func, Arity, Env, Line, State) -> State.
%%  Check if Func/Arity is bound or an auto-imported BIF.

check_func(F, Ar, Env, L, St) ->
    case lfe_env:is_fbound(F, Ar, Env) orelse
        lfe_internal:is_lfe_bif(F, Ar) orelse
        lfe_internal:is_erl_bif(F, Ar) of
        true -> St;
        false -> undefined_function_error(L, {F,Ar}, St)
    end.

%% check_body(Form, Body, Env, Line, State) -> State.
%% Check the calls in a body. A body is a proper list of calls. Env is
%% the set of known bound variables.

check_body(Form, Body, Env, L, St) ->
    check_foreach(fun (E, S) -> check_expr(E, Env, L, S) end,
                  fun (S) -> add_error(L, {bad_body,Form}, S) end,
                  St, Body).

%% check_args(Args, Env, Line, State) -> State.
%% Check the expressions in an argument list.

check_args(Args, Env, L, St) ->
    check_foreach(fun (A, S) -> check_expr(A, Env, L, S) end,
                  fun (S) -> add_error(L, bad_args, S) end,
                  St, Args).

%% check_exprs(Exprs, Env, Line, State) -> State.
%% Check a list of expressions. We know it's a proper list.

check_exprs(Es, Env, L, St) ->
    foldl(fun (E, S) -> check_expr(E, Env, L, S) end, St, Es).

%% expr_bitsegs(BitSegs, Env, Line, State) -> State.

expr_bitsegs(Segs, Env, L, St0) ->
    foreach_form(fun (S, St) -> bitseg(S, Env, L, St, fun check_expr/4) end,
         binary, L, St0, Segs).

%% bitseg(BitSeg, Env, Line, State) -> State.
%% bitspecs(BitSpecs, Env, Line, State) -> State.
%% bit_size(Size, Type, Env, Line, State) -> State.
%% Functions for checking expression bitsegments.

bitseg([Val|Specs]=Seg, Env, L, St0, Check) ->
    case lfe_lib:is_posint_list(Seg) of         %Is bitseg a string?
        true -> St0;                            %A string
        false ->                                %A value and spec
            St1 = bitspecs(Specs, Env, L, St0, Check),
            case lfe_lib:is_posint_list(Val) of %Is Val a string?
                true -> St1;
                false -> Check(Val, Env, L, St1)
            end
    end;
bitseg(Val, Env, L, St, Check) ->
    Check(Val, Env, L, St).

bitspecs(Specs, Env, L, St, Check) ->
    case lfe_bits:get_bitspecs(Specs) of
        {ok,Sz,Ty} -> bit_size(Sz, Ty, Env, L, St, Check);
        {error,E} -> add_error(L, E, St)
    end.

%% Catch the case where size was explicitly given as 'undefined' or
%% 'all' for the wrong type.

bit_size(all, {Ty,_,_,_}, _, L, St, _) ->
    if Ty =:= binary -> St;
       true -> illegal_bitsize_error(L, St)
    end;
bit_size(undefined, {Ty,_,_,_}, _, L, St, _) ->
    if Ty =:= utf8; Ty =:= utf16; Ty =:= utf32 -> St;
       true -> illegal_bitsize_error(L, St)
    end;
bit_size(Sz, _, Env, L, St, Check) -> Check(Sz, Env, L, St).

%% check_map(Pairs, Env, Line, State) -> State.
%% check_map_size(Form, Map, Env, Line, State) -> State.
%% check_map_get(Form, Map, Key, Env, Line, State) -> State.
%% check_map_set(Form, Map, Pairs, Line, State) -> State.
%% check_map_update(Form, Args, Pairs, Line, State) -> State.
%% check_map_remove(Form, Args, Keys, Line, State) -> State.
%%  Functions for checking maps, these always return errors if system
%%  does not support maps.

-ifdef(HAS_MAPS).
check_map(Pairs, Env, L, St) ->
    check_map_pairs(map, Pairs, Env, L, St).

check_map_size(_Form, Map, Env, L, St) ->
    check_expr(Map, Env, L, St).

check_map_get(_Form, Map, Key, Env, L, St0) ->
    St1 = check_expr(Map, Env, L, St0),
    map_key(Key, Env, L, St1).

check_map_set(Form, Map, Pairs, Env, L, St0) ->
    St1 = check_expr(Map, Env, L, St0),
    check_map_pairs(Form, Pairs, Env, L, St1).

check_map_update(Form, Map, Pairs, Env, L, St0) ->
    St1 = check_expr(Map, Env, L, St0),
    check_map_pairs(Form, Pairs, Env, L, St1).

check_map_remove(_Form, Map, Keys, Env, L, St0) ->
    St1 = check_expr(Map, Env, L, St0),
    check_exprs(Keys, Env, L, St1).

check_map_pairs(Form, [K,V|As], Env, L, St0) ->
    St1 = check_map_assoc(K, V, Env, L, St0),
    check_map_pairs(Form, As, Env, L, St1);
check_map_pairs(_, [],  _, _, St) -> St;
check_map_pairs(Form, _, _, L, St) ->
    bad_form_error(L, Form, St).

check_map_assoc(K, V, Env, L, St0) ->
    St1 = map_key(K, Env, L, St0),
    check_expr(V, Env, L, St1).

%% map_key(Key, Env, L, State) -> State.
%%  A map key can only be a literal in 17 but can be anything in 18.

-ifdef(HAS_FULL_KEYS).
map_key(Key, Env, L, St) ->
    check_expr(Key, Env, L, St).
-else.
map_key(Key, _, L, St) ->
    case is_map_key(Key) of
        true -> St;
        false -> illegal_mapkey_error(L, Key, St)
    end.

is_map_key(?Q(Lit)) -> is_literal(Lit);
is_map_key([_|_]=L) ->
    lfe_lib:is_posint_list(L);                  %Literal strings only
is_map_key(E) when is_atom(E) -> false;
is_map_key(Lit) -> is_literal(Lit).
-endif.

-else.
check_map(Ps, _, L, St) ->
    undefined_function_error(L, {map,safe_length(Ps)}, St).

check_map_size(Form, _, _, L, St) ->
    undefined_function_error(L, {Form,1}, St).

check_map_get(Form, _, _, _, L, St) ->
    undefined_function_error(L, {Form,2}, St).

check_map_set(Form, _, Ps, _, L, St) ->
    undefined_function_error(L, {Form,safe_length(Ps)+1}, St).

check_map_update(Form, _, Ps, _, L, St) ->
    undefined_function_error(L, {Form,safe_length(Ps)+1}, St).

check_map_remove(Form, _, Ks, _, L, St) ->
    undefined_function_error(L, {Form,safe_length(Ks)+1}, St).
-endif.

%% check_record(Record, Fields, Env, Line, State) -> State.
%%  Check record usage against its definition.

check_record(Name, Fields, Env, L, #lfe_lint{recs=Recs}=St)
  when is_atom(Name) ->
    case orddict:find(Name, Recs) of
        {ok,Rfields} ->
            check_record_fields(Name, Fields, Rfields, Env, L, St);
        error ->
            undefined_record_error(L, Name, St)
    end;
check_record(Name, _, _, L, St) ->
    bad_record_error(L, Name, St).

check_record_fields(Name, ['_',_Val|Fs], Rfs, Env, L, St) ->
    %% The _ field is special!
    check_record_fields(Name, Fs, Rfs, Env, L, St);
check_record_fields(Name, [F,Val|Fs], Rfs, Env, L, St0) ->
    St1 = case lists:member(F, Rfs) of
              true ->
                  check_expr(Val, Env, L, St0);
              false ->
                  undefined_field_error(L, Name, F, St0)
          end,
    check_record_fields(Name, Fs, Rfs, Env, L, St1);
check_record_fields(Name, [F], _Rfs, _Env, L, St) ->
    missing_field_value_error(L, Name, F, St);
check_record_fields(_Name, [], _, _, _, St) -> St;
check_record_fields(Name, Pat, _Rfs, _, L, St) ->
    bad_field_error(L, Name, Pat, St).

%% check_record_field(Record, Field, Line, State) -> State.
%%  Check whether record has a field.

check_record_field(Name, F, L, #lfe_lint{recs=Recs}=St)
  when is_atom(Name) ->
    case orddict:find(Name, Recs) of
        {ok,Rfields} ->
            case lists:member(F, Rfields) of
                true -> St;
                false ->
                    undefined_field_error(L, Name, F, St)
            end;
        error ->
            undefined_record_error(L, Name, St)
    end;
check_record_field(Name, _F, L, St) ->
    bad_record_error(L, Name, St).

%% check_lambda(LambdaBody, Env, Line, State) -> State.
%% Check form (lambda Args ...).

check_lambda([Args|Body], Env, L, St0) ->
    {Vs,St1} = check_lambda_args(Args, L, St0),
    check_body(lambda, Body, add_vbindings(Vs, Env), L, St1);
check_lambda(_, _, L, St) -> bad_form_error(L, lambda, St).

check_lambda_args(Args, L, St) ->
    %% Check for multiple variables but allow don't care variables,
    %% same rules as for pattern symbols.
    Check = fun (A, {As,S}) -> pat_symb(A, As, L, S) end,
    case lfe_lib:is_symb_list(Args) of
        true -> foldl(Check, {[],St}, Args);
        false -> {[],bad_form_error(L, lambda, St)}
    end.

%% check_match_lambda(MatchBody, Env, Line, State) -> State.
%%  Check form (match-lambda Clause ...), must be at least one clause.
%%  Use arity of 1st as THE arity. Do one pass to get errors in right
%%  order.

check_match_lambda([C|_]=Cls, Env, L, St) ->
    Ar = ml_arity(C),                           %Arity of 1st clause
    check_ml_clauses(Cls, Ar, Env, L, St);
check_match_lambda(_, _, L, St) ->              %Totally wrong, no clauses
    bad_form_error(L, 'match-lambda', St).

ml_arity([Pat|_]) ->
    safe_length(Pat, -1);
ml_arity(_) -> -1.

check_ml_clause([Pat|Rest]=C, Ar, Env0, L, St0) ->
    St1 = case ml_arity(C) =:= Ar of
              true -> St0;
              false -> add_error(L, bad_arity, St0)
          end,
    check_clause('match-lambda', [[list|Pat]|Rest], Env0, L, St1);
check_ml_clause(_, _, _, L, St) ->
    bad_form_error(L, clause, St).

check_ml_clauses(Cls, Ar, Env, L, St) ->
    foreach_form(fun (C, S) -> check_ml_clause(C, Ar, Env, L, S) end,
                 'match-lambda', L, St, Cls).

%% check_let(LetBody, Env, Line, State) -> {Env,State}.
%%  Check let variable bindings and then body. Must be careful to use
%%  correct bindings.

check_let([Vbs|Body], Env, L, St0) ->
    Check = fun (Vb, Pvs, Sta) ->
                    {Pv,Stb} = check_let_vb(Vb, Env, L, Sta),
                    Stc = case intersection(Pv, Pvs) of
                              [] -> Stb;
                              Ivs -> multi_var_error(L, Ivs, Stb)
                          end,
                    {union(Pv, Pvs), Stc}
            end,
    {Pvs,St1} = foldl_form(Check, 'let', L, [], St0, Vbs),
    check_body('let', Body, add_vbindings(Pvs, Env), L, St1);
check_let(_, _, L, St) ->
    bad_form_error(L, 'let', St).

%% check_let_vb(VarBind, Env, Line, State) -> {Env,State}.
%%  Check a variable binding of form [Pat,[when,Guard],Val] or
%%  [Pat,Val].

check_let_vb([_|_]=Vb, Env, L, St0) ->
    %% Get the environments right here!
    case pattern_guard(Vb, Env, L, St0) of
        {[Val],Pvs,_,St1} ->                    %One value expression only
            {Pvs,check_expr(Val, Env, L, St1)};
        {_,_,_,St1} -> {[],bad_form_error(L, 'let', St1)}
    end;
check_let_vb(_, _, L, St) -> {[],bad_form_error(L, 'let', St)}.

%% check_let_function(FletBody, Env, Line, State) -> {Env,State}.
%%  Check a let-function form (let-function FuncBindings ... ).

check_let_function([Fbs0|Body], Env0, L, St0) ->
    %% Collect correct function definitions.
    {Fbs1,St1} = collect_let_funcs(Fbs0, 'let-function', L, St0),
    {_,Env1,St2} = check_let_bindings(Fbs1, Env0, St1),
    check_body('let-function', Body, Env1, L, St2).

%% check_letrec_function(FletrecBody, Env, Line, State) -> {Env,State}.
%%  Check a letrec-function form (letrec-function FuncBindings ... ).

check_letrec_function([Fbs0|Body], Env0, L, St0) ->
    %% Collect correct function definitions.
    {Fbs1,St1} = collect_let_funcs(Fbs0, 'letrec-function', L, St0),
    {_,Env1,St2} = check_letrec_bindings(Fbs1, Env0, St1),
    check_body('letrec-function', Body, Env1, L, St2).

%% collect_let_funcs(FuncDefs, Type, Line, State) -> {Funcbindings,State}.
%%  Collect the function definitions for a let/letrec-function
%%  checking right types. Returns same format as top-level collect.

collect_let_funcs(Fbs0, Type, L, St0) ->
    Check = fun ([V,['lambda'|_]=Lambda], Fbs, St) when is_atom(V) ->
                    {[{V,Lambda,L}|Fbs],St};
                ([V,['match-lambda'|_]=Match], Fbs, St) when is_atom(V) ->
                    {[{V,Match,L}|Fbs],St};
                (_, Fbs, St) -> {Fbs,bad_form_error(L, Type, St)}
            end,
    foldr_form(Check, Type, L, [], St0, Fbs0).  %Preserve order

%% check_let_bindings(FuncBindings, Env, State) -> {Funcs,Env,State}.
%%  Check the function bindings and return new environment. We only
%%  have to worry about checking for the valid forms as the rest will
%%  already be reported. Use explicit line number in element.

check_let_bindings(Fbs, Env0, St0) ->
    {Fs,St1} = check_fbindings(Fbs, St0),
    %% Now check function definitions.
    St2 = foldl(fun ({_,[lambda|Lambda],L}, St) ->
                        check_lambda(Lambda, Env0, L, St);
                    ({_,['match-lambda'|Match],L}, St) ->
                        check_match_lambda(Match, Env0, L, St)
                end, St1, Fbs),
    %% Add to environment
    Env1 = foldl(fun ({F,A}, Env) -> add_fbinding(F, A, Env) end, Env0, Fs),
    {Fs,Env1,St2}.

%% check_letrec_bindings(FuncBindings, Env, State) -> {Funcs,Env,State}.
%%  Check the function bindings and return new environment. We only
%%  have to worry about checking for the valid forms as the rest will
%%  already be reported. Use explicit line number in element.

check_letrec_bindings(Fbs, Env0, St0) ->
    {Fs,St1} = check_fbindings(Fbs, St0),
    %% Add to the environment.
    Env1 = foldl(fun ({F,A}, Env) -> add_fbinding(F, A, Env) end, Env0, Fs),
    %% Now check function definitions.
    St2 = foldl(fun ({_,[lambda|Lambda],L}, St) ->
                        check_lambda(Lambda, Env1, L, St);
                    ({_,['match-lambda'|Match],L}, St) ->
                        check_match_lambda(Match, Env1, L, St)
                end, St1, Fbs),
    {Fs,Env1,St2}.

%% check_fbindings(FuncBindings, State) -> {Funcs,State}.
%%  Check function bindings for format and for multiple fucntion
%%  definitions.

check_fbindings(Fbs0, St0) ->
    AddFb = fun(F, Fs, L, St) ->
                    case member(F, Fs) of
                        true -> {Fs,add_error(L, {redefine_function,F}, St)};
                        false -> {add_element(F, Fs),St}
                    end
            end,
    Check = fun ({V,[lambda,Args|_],L}, {Fs,St}) ->
                    case lfe_lib:is_symb_list(Args) of
                        true -> AddFb({V,length(Args)}, Fs, L, St);
                        false -> {Fs,bad_form_error(L, lambda, St)}
                    end;
                ({V,['match-lambda',[Pats|_]|_],L}, {Fs,St}) ->
                    case lfe_lib:is_proper_list(Pats) of
                        true -> AddFb({V,length(Pats)}, Fs, L, St);
                        false -> {Fs,bad_form_error(L, 'match-lambda', St)}
                    end;
                (_, Acc) -> Acc                 %Error here flagged elsewhere
            end,
    foldl(Check, {[],St0}, Fbs0).

%% check_if(IfBody, Env, Line, State) -> State.
%% Check form (if Test True [False]).

check_if([Test,True,False], Env, L, St) ->
    check_exprs([Test,True,False], Env, L, St);
check_if([Test,True], Env, L, St) ->
    check_exprs([Test,True], Env, L, St);
check_if(_, _, L, St) ->
    bad_form_error(L, 'if', St).

%% check_case(CaseBody, Env, Line, State) -> State.
%%  Check form (case Expr Clause ...), must be at least one clause.

check_case([E|[_|_]=Cls], Env, L, St0) ->
    St1 = check_expr(E, Env, L, St0),
    check_case_clauses(Cls, Env, L, St1);
check_case(_, _, L, St) ->
    bad_form_error(L, 'case', St).

check_case_clauses(Cls, Env, L, St) ->
    foreach_form(fun (Cl, S) -> check_clause('case', Cl, Env, L, S) end,
                 'case', L, St, Cls).

check_rec_clauses([['after',T|B]], Env, L, St0) ->
    St1 = check_expr(T, Env, L, St0),
    check_body('receive', B, Env, L, St1);
check_rec_clauses([['after'|_]|Cls], Env, L, St) ->
    %% Only allow after last and with timeout.
    check_rec_clauses(Cls, Env, L, bad_form_error(L, 'receive', St));
check_rec_clauses([Cl|Cls], Env, L, St) ->
    check_rec_clauses(Cls, Env, L, check_clause('receive', Cl, Env, L, St));
check_rec_clauses([], _, _, St) -> St;
check_rec_clauses(_, _, L, St) -> bad_form_error(L, 'receive', St).

check_clause(Form, [_|_]=Cl, Env0, L, St0) ->
    {B,_,Env1,St1} = pattern_guard(Cl, Env0, L, St0),
    check_body(Form, B, Env1, L, St1);
check_clause(Form, _, _, L, St) -> bad_form_error(L, Form, St).

%% check_try(TryBody, Env, Line, State) -> State.
%%  Check a (try ...) form making sure that the right combination of
%%  options are present. Case is optional, but we must have at least
%%  one of catch and after.

check_try([E,['case'|Cls]|Catch], Env, L, St0) ->
    St1 = check_expr(E, Env, L, St0),
    St2 = check_case_clauses(Cls, Env, L, St1),
    check_try_catch(Catch, Env, L, St2);
check_try([E|Catch], Env, L, St0) ->
    St1 = check_expr(E, Env, L, St0),
    check_try_catch(Catch, Env, L, St1);
check_try(_, _, L, St) -> bad_form_error(L, 'try', St).

check_try_catch([['catch'|Catch]], Env, L, St) ->
    check_catch_clauses(Catch, Env, L, St);
check_try_catch([['catch'|Catch],['after'|After]], Env, L, St0) ->
    St1 = check_catch_clauses(Catch, Env, L, St0),
    check_body('try', After, Env, L, St1);
check_try_catch([['after'|After]], Env, L, St) ->
    check_body('try', After, Env, L, St);
check_try_catch(_, _, L, St) -> bad_form_error(L, 'try', St).

check_catch_clauses(Cls, Env, L, St) ->
    foreach_form(fun (C, S) -> check_catch_clause(C, Env, L, S) end,
                 'try', L, St, Cls).

check_catch_clause(['_'|_]=Cl, Env, L, St) ->
    check_clause('catch', Cl, Env, L, St);
check_catch_clause([[tuple,_,_,Stack]|_]=Cl, Env, L, St0) ->
    %% Stack must be an unbound variable.
    St1 = case is_atom(Stack) and not lfe_env:is_vbound(Stack, Env) of
              true -> St0;
              false -> add_error(L, {illegal_stacktrace,Stack}, St0)
          end,
    check_clause('catch', Cl, Env, L, St1);
check_catch_clause([Other|_], _Env, L, St) ->
    add_error(L, {illegal_exception,Other}, St).

%% pattern_guard([Pat{,Guard}|Body], Env, L, State) ->
%%      {Body,PatVars,Env,State}.
%%  Check pattern and guard in a clause. We know there is at least pattern!

pattern_guard([Pat,['when'|G]|Body], Env0, L, St0) ->
    {Pvs,St1} = pattern(Pat, Env0, L, St0),
    Env1 = add_vbindings(Pvs, Env0),
    St2 = check_guard(G, Env1, L, St1),
    {Body,Pvs,Env1,St2};
pattern_guard([Pat|Body], Env0, L, St0) ->
    {Pvs,St1} = pattern(Pat, Env0, L, St0),
    Env1 = add_vbindings(Pvs, Env0),
    {Body,Pvs,Env1,St1}.

%% check_guard(GuardTests, Env, Line, State) -> State.
%% Check a guard.

check_guard(G, Env, L, St) -> check_gbody(G, Env, L, St).

%% check_gbody(Body, Env, Line, State) -> State.
%%  Check guard expressions in a body

check_gbody(Exprs, Env, L, St) ->
    check_foreach(fun (E, S) -> check_gexpr(E, Env, L, S) end,
                  fun (S) -> add_error(L, bad_guard, S) end,
                  St, Exprs).

%% check_gexpr(Call, Env, Line, State) -> State.
%%  Check a guard expression. This is a restricted body expression.

%% Check the Core data special cases.
check_gexpr(?Q(Lit), Env, L, St) -> literal(Lit, Env, L, St);
check_gexpr([cons|[_,_]=As], Env, L, St) -> check_gargs(As, Env, L, St);
check_gexpr([car,E], Env, L, St) -> check_gexpr(E, Env, L, St);
check_gexpr([cdr,E], Env, L, St) -> check_gexpr(E, Env, L, St);
check_gexpr([list|As], Env, L, St) -> check_gargs(As, Env, L, St);
check_gexpr([tuple|As], Env, L, St) -> check_gargs(As, Env, L, St);
check_gexpr([tref|[_,_]=As], Env, L, St) -> check_gargs(As, Env, L, St);
check_gexpr([binary|Segs], Env, L, St) -> gexpr_bitsegs(Segs, Env, L, St);
%% Check map special forms which translate into legal guard expressions.
check_gexpr([map|As], Env, L, St) ->
    check_gmap(As, Env, L, St);
check_gexpr([msiz,Map], Env, L, St) ->
    check_gmap_size(msiz, Map, Env, L, St);
check_gexpr([mref,Map,Key], Env, L, St) ->
    check_gmap_get(mref, Map, Key, Env, L, St);
check_gexpr([mset,Map|As], Env, L, St) ->
    check_gmap_set(mset, Map, As, Env, L, St);
check_gexpr([mupd,Map|As], Env, L, St) ->
    check_gmap_update(mupd, Map, As, Env, L, St);
check_gexpr(['map-size',Map], Env, L, St) ->
    check_gmap_size('map-size', Map, Env, L, St);
check_gexpr(['map-get',Map,Key], Env, L, St) ->
    check_gmap_get('map-get', Map, Key, Env, L, St);
check_gexpr(['map-set',Map|As], Env, L, St) ->
    check_gmap_set('map-set', Map, As, Env, L, St);
check_gexpr(['map-update',Map|As], Env, L, St) ->
    check_gmap_update('map-update', Map, As, Env, L, St);
%% Check record special forms.
check_gexpr(['record-index',Name,F], Env, L, St) ->
    check_record(Name, [F], Env, L, St);
check_gexpr(['record-field',E,Name,F], Env, L, St0) ->
    St1 = check_gexpr(E, Env, L, St0),
    check_record(Name, [F], Env, L, St1);
%% Special known data type operations.
check_gexpr(['andalso'|Es], Env, L, St) ->
    check_gargs(Es, Env, L, St);
check_gexpr(['orelse'|Es], Env, L, St) ->
    check_gargs(Es, Env, L, St);
check_gexpr([call,?Q(erlang),?Q(Fun)|As], Env, L, St0) ->
    St1 = check_gargs(As, Env, L, St0),
    %% It must be a legal guard bif here.
    case lfe_internal:is_guard_bif(Fun, safe_length(As)) of
        true -> St1;
        false -> illegal_guard_error(L, St1)
    end;
%% Finally the general case.
check_gexpr([call|_], _, L, St) ->              %Other calls not allowed
    illegal_guard_error(L, St);
check_gexpr([Fun|As], Env, L, St0) when is_atom(Fun) ->
    St1 = check_gargs(As, Env, L, St0),
    check_gfunc(Fun, safe_length(As), Env, L, St1);
check_gexpr([_|As]=S, Env, L, St0) ->            %Test if literal string
    case lfe_lib:is_posint_list(S) of
        true -> St0;
        false ->
            %% Function here is an expression, report error and check args.
            St1 = bad_guard_form_error(L, application, St0),
            check_gargs(As, Env, L, St1)
    end;
check_gexpr(Symb, Env, L, St) when is_atom(Symb) ->
    check_symb(Symb, Env, L, St);
check_gexpr(Lit, Env, L, St) ->                 %Everything else is a literal
    literal(Lit, Env, L, St).

%% check_gfunc(Func, Arity, Env, Line, State) -> State.
%%  Check if Func/Arity is not bound and an auto-imported guard BIF.

check_gfunc(F, Ar, Env, L, St) ->
    case (not lfe_env:is_fbound(F, Ar, Env)) andalso
         lfe_internal:is_guard_bif(F, Ar) of
        true -> St;
        false -> illegal_guard_error(L, St)
    end.

%% check_gargs(Args, Env, Line, State) -> State.
%% check_gexprs(Exprs, Env, Line, State) -> State.
%%  The guard counter parts. Check_gexprs assumes a proper list.

check_gargs(Args, Env, L, St) ->
    check_foreach(fun (A, S) -> check_gexpr(A, Env, L, S) end,
                  fun (S) -> add_error(L, bad_gargs, S) end,
                  St, Args).

%% check_gexprs(Es, Env, L, St) ->
%%     foldl(fun (E, S) -> check_gexpr(E, Env, L, S) end, St, Es).

%% gexpr_bitsegs(BitSegs, Env, Line, State) -> State.

gexpr_bitsegs(Segs, Env, L, St0) ->
    check_foreach(fun (S, St) -> bitseg(S, Env, L, St, fun check_gexpr/4) end,
                  fun (St) -> bad_guard_form_error(L, binary, St) end, St0, Segs).

%% check_gmap_size(Form, Map, Env, Line, State) -> State.
%% check_gmap_get(Form, Map, Key, Env, Line, State) -> State.
%% check_gmap_set(Form, Map, Pairs, Line, State) -> State.
%% check_gmap_update(Form, Args, Pairs, Line, State) -> State.
%%  Functions for checking maps, these always return errors if system
%%  does not support maps.

-ifdef(HAS_MAPS).
check_gmap(Pairs, Env, L, St) ->
    check_gmap_pairs(map, Pairs, Env, L, St).

check_gmap_size(_Form, Map, Env, L, St) ->
    check_gexpr(Map, Env, L, St).

check_gmap_get(_Form, Map, Key, Env, L, St0) ->
    St1 = check_gexpr(Map, Env, L, St0),
    gmap_key(Key, Env, L, St1).

check_gmap_set(Form, Map, Pairs, Env, L, St0) ->
    St1 = check_expr(Map, Env, L, St0),
    check_gmap_pairs(Form, Pairs, Env, L, St1).

check_gmap_update(Form, Map, Pairs, Env, L, St0) ->
    St1 = check_gexpr(Map, Env, L, St0),
    check_gmap_pairs(Form, Pairs, Env, L, St1).

check_gmap_pairs(Form, [K,V|As], Env, L, St0) ->
    St1 = check_gmap_assoc(K, V, Env, L, St0),
    check_gmap_pairs(Form, As, Env, L, St1);
check_gmap_pairs(_, [],  _, _, St) -> St;
check_gmap_pairs(Form, _, _, L, St) ->
    bad_form_error(L, Form, St).

check_gmap_assoc(K, V, Env, L, St0) ->
    St1 = gmap_key(K, Env, L, St0),
    check_gexpr(V, Env, L, St1).

%% gmap_key(Key, Env, L, State) -> State.
%%  A map key can only be a literal in 17 but can be anything in 18.

-ifdef(HAS_FULL_KEYS).
gmap_key(Key, Env, L, St) ->
    check_gexpr(Key, Env, L, St).
-else.
gmap_key(Key, _, L, St) ->
    case is_map_key(Key) of
        true -> St;
        false -> illegal_mapkey_error(L, Key, St)
    end.
-endif.

-else.
check_gmap(Ps, _, L, St) ->
    undefined_function_error(L, {map,safe_length(Ps)}, St).

check_gmap_size(Form, _, _, L, St) ->
    undefined_function_error(L, {Form,1}, St).

check_gmap_get(Form, _, _, _, L, St) ->
    undefined_function_error(L, {Form,2}, St).

check_gmap_set(Form, _, Ps, _, L, St) ->
    undefined_function_error(L, {Form,safe_length(Ps)+1}, St).

check_gmap_update(Form, _, Ps, _, L, St) ->
    undefined_function_error(L, {Form,safe_length(Ps)+1}, St).
-endif.

%% pattern(Pattern, Env, L, State) -> {PatVars,State}.
%% pattern(Pattern, PatVars, Env, L, State) -> {PatVars,State}.
%%  Return the *set* of Variables in Pattern.  Patterns are
%%  complicated by the fact that we don't allow multiple occurrence of
%%  variables, this is an error. Explicit guards tests are
%%  necessary. So we need to carry around the current pattern
%%  variables as well as the environment.

pattern(Pat, Env, L, St) ->
    %% io:fwrite("pat: ~p\n", [Pat]),
    %% pattern/5 should never fail!
    pattern(Pat, [], Env, L, St).
%%     try
%%     pattern(Pat, [], Env, L, St)
%%     catch
%%     _:_ -> {[],illegal_pattern_error(L, Pat, St)}
%%     end.

pattern(?Q(Lit), Pvs, Env, L, St) ->
    {Pvs,literal(Lit, Env, L, St)};
pattern(['=',P1,P2], Pvs0, Env, L, St0) ->
    %% Must check patterns together as same variable can occur
    %% in both branches.
    {Pvs1,St1} = pattern(P1, Pvs0, Env, L, St0),
    {Pvs2,St2} = pattern(P2, Pvs1, Env, L, St1),
    St3 = case is_pat_alias(P1, P2) of
              true -> St2;                      %Union of variables now visible
              false -> add_error(L, bad_alias, St2)
          end,
    {Pvs2,St3};
pattern([cons,H,T], Pvs0, Env, L, St0) ->       %Explicit cons constructor
    {Pvs1,St1} = pattern(H, Pvs0, Env, L, St0),
    pattern(T, Pvs1, Env, L, St1);
pattern([list|Ps], Pvs, Env, L, St) ->          %Explicit list constructor
    pat_list(Ps, Pvs, Env, L, St);
pattern([tuple|Ps], Pvs, Env, L, St) ->         %Tuple elements
    pat_list(Ps, Pvs, Env, L, St);
pattern([binary|Segs], Pvs, Env, L, St) ->
    pat_binary(Segs, Pvs, Env, L, St);
pattern([map|Ps], Pvs, Env, L, St) ->
    pat_map(Ps, Pvs, Env, L, St);
%% Check record patterns.
pattern(['make-record',Name|Fs], Pvs, Env, L, St) ->
    check_record_pat(Name, Fs, Pvs, Env, L, St);
pattern(['record-index',Name,F], _Pvs, _Env, L, St) ->
    check_record_field(Name, F, L, St);
%% Check old no contructor list forms.
pattern([_|_]=List, Pvs, _, L, St) ->
    case lfe_lib:is_posint_list(List) of
        true -> {Pvs,St};                       %A string
        false ->                                %Illegal pattern
            {Pvs,illegal_pattern_error(L, List, St)}
    end;
pattern([], Pvs, _, _, St) -> {Pvs,St};
pattern(Symb, Pvs, _, L, St) when is_atom(Symb) ->
    pat_symb(Symb, Pvs, L, St);
pattern(Lit, Pvs, Env, L, St) ->
    {Pvs,literal(Lit, Env, L, St)}.             %Everything else is a literal

pat_list([P|Ps], Pvs0, Env, L, St0) ->
    {Pvs1,St1} = pattern(P, Pvs0, Env, L, St0),
    pat_list(Ps, Pvs1, Env, L, St1);
pat_list([], Pvs, _, _, St) -> {Pvs,St};
pat_list(Pat, Pvs, _, L, St) ->
    {Pvs,illegal_pattern_error(L, Pat, St)}.

pat_symb('_', Pvs, _, St) -> {Pvs,St};          %Don't care variable
pat_symb(Symb, Pvs, _, St) ->
    {add_element(Symb, Pvs),St}.                %Add that to pattern vars

%% is_pat_alias(Pattern, Pattern) -> true | false.
%%  Check if two aliases are compatible. Note that binaries can never
%%  be aliased, this is from erlang.

is_pat_alias(?Q(P1), ?Q(P2)) -> P1 =:= P2;
is_pat_alias([tuple|Ps1], [tuple|Ps2]) ->
    is_pat_alias_list(Ps1, Ps2);
%% is_pat_alias([tuple|Ps1], P2) when is_tuple(P2) ->
%%     is_pat_alias_list(Ps1, tuple_to_list(P2));
%% is_pat_alias(P1, [tuple|Ps2]) when is_tuple(P1) ->
%%     is_pat_alias_list(tuple_to_list(P1), Ps2);
is_pat_alias([binary|_], [binary|_]) -> false;
is_pat_alias([cons,H1,T1], [cons,H2,T2]) ->
    is_pat_alias(H1, H2) andalso is_pat_alias(T1, T2);
is_pat_alias([cons,H1,T1], [list,H2|T2]) ->
    is_pat_alias(H1, H2) andalso is_pat_alias(T1, [list|T2]);
is_pat_alias([list|Ps1], [list|Ps2]) ->
    is_pat_alias_list(Ps1, Ps2);
is_pat_alias([list,H1|T1], [cons,H2,T2]) ->
    is_pat_alias(H1, H2) andalso is_pat_alias([list|T1], T2);
%% Check against old no contructor list forms.
is_pat_alias([list|_]=P1, P2) when is_list(P2) ->
    is_pat_alias(P1, [list|P2]);
is_pat_alias([cons,_,_]=P1, [H2|T2]) ->
    is_pat_alias(P1, [cons,H2,T2]);
is_pat_alias(P1, [list|_]=P2) when is_list(P1) ->
    is_pat_alias([list|P1], P2);
is_pat_alias([H1|T1], [cons,_,_]=P2) ->
    is_pat_alias([cons,H1,T1], P2);
%% Check old against old no constructor list forms.
is_pat_alias([P1|Ps1], [P2|Ps2]) ->
    is_pat_alias(P1, P2) andalso is_pat_alias(Ps1, Ps2);
is_pat_alias(P1, _) when is_atom(P1) -> true;   %Variable
is_pat_alias(_, P2) when is_atom(P2) -> true;
is_pat_alias(P1, P2) -> P1 =:= P2.              %Atomic

is_pat_alias_list([P1|Ps1], [P2|Ps2]) ->
    is_pat_alias(P1, P2) andalso is_pat_alias_list(Ps1, Ps2);
is_pat_alias_list([], []) -> true;
is_pat_alias_list(_, _) -> false.

%% pat_binary(BitSegs, PatVars, Env, Line, State) -> {PatVars,State}.
%% pat_bitsegs(BitSegs, BitVars, PatVars, Env, Line, State) ->
%%     {BitVars,PatVars,State}.
%% pat_bitseg(BitSeg, BitVars, PatVars, Env, Line, State) ->
%%     {BitVars,PatVars,State}.
%% pat_bitspecs(BitSpecs, BitVars, PatVars, Env, Line, State) -> State.
%% pat_bit_size(Size, Type, BitVars, PatVars, Env, Line, State) -> State.
%% pat_bit_expr(BitElement, BitVars, PatVars, Env, Line, State) ->
%%     {BitVars,PatVars,State}.
%%  Functions for checking pattern bitsegments. This gets a bit
%%  complex as we allow using values from left but only as sizes, no
%%  implicit equality checks so multiple pattern variables are an
%%  error. We only update BitVars during the match.

pat_binary(Segs, Pvs, Env, L, St) ->
    pat_bitsegs(Segs, [], Pvs, Env, L, St).

pat_bitsegs(Segs, Bvs0, Pvs, Env, L, St0) ->
    {Bvs1,St1} =
        check_foldl(fun (Seg, Bvs, St) ->
                            pat_bitseg(Seg, Bvs, Pvs, Env, L, St)
                    end,
                    fun (St) -> bad_pattern_error(L, binary, St) end,
                    Bvs0, St0, Segs),
    {union(Bvs1, Pvs),St1}.                     %Add bitvars to patvars

pat_bitseg([Pat|Specs]=Seg, Bvs, Pvs, Env, L, St0) ->
    case lfe_lib:is_posint_list(Seg) of         %Is bitseg a string?
        true -> {Bvs,St0};                      %A string
        false ->                                %A pattern and spec
            St1 = pat_bitspecs(Specs, Bvs, Pvs, Env, L, St0),
            case lfe_lib:is_posint_list(Pat) of %Is Pat a string?
                true -> {Bvs,St1};
                false -> pat_bit_expr(Pat, Bvs, Pvs, Env, L, St1)
            end
    end;
pat_bitseg(Pat, Bvs, Pvs, Env, L, St) ->
    pat_bit_expr(Pat, Bvs, Pvs, Env, L, St).

pat_bitspecs(Specs, Bvs, Pvs, Env, L, St) ->
    case lfe_bits:get_bitspecs(Specs) of
        {ok,Sz,Ty} -> pat_bit_size(Sz, Ty, Bvs, Pvs, Env, L, St);
        {error,E} -> add_error(L, E, St)
    end.

%% Catch the case where size was explicitly given as 'undefined' or
%% 'all' for the wrong type.

pat_bit_size(all, {Ty,_,_,_}, _, _, _, L, St) ->
    if Ty =:= binary -> St;
       true -> illegal_bitsize_error(L, St)
    end;
pat_bit_size(undefined, {Ty,_,_,_}, _, _, _, L, St) ->
    if Ty =:= utf8; Ty =:= utf16; Ty =:= utf32 -> St;
       true -> illegal_bitsize_error(L, St)
    end;
pat_bit_size(N, _, _, _, _, _, St) when is_integer(N), N > 0 -> St;
pat_bit_size(S, _, Bvs, _, Env, L, St) when is_atom(S) ->
    %% Size must be bound here or occur earlier in binary pattern.
    case is_element(S, Bvs) or lfe_env:is_vbound(S, Env) of
        true -> St;
        false -> add_error(L, {unbound_symb,S}, St)
    end;
pat_bit_size(_, _, _, _, _, L, St) -> illegal_bitsize_error(L, St).

pat_bit_expr(N, Bvs, _, _, _, St) when is_number(N) -> {Bvs,St};
pat_bit_expr('_', Bvs, _, _, _, St) -> {Bvs,St};
pat_bit_expr(S, Bvs, _, _, _, St) when is_atom(S) ->
    {add_element(S, Bvs),St};
pat_bit_expr(_, Bvs, _, _, L, St) ->
    {Bvs,add_error(L, illegal_bitseg, St)}.

%% pat_map(Pairs, PatVars, Env, Line, State) -> {PatVars,State}.

-ifdef(HAS_MAPS).
pat_map([K,V|As], Pvs0, Env, L, St0) ->
    {Pvs1,St1} = pat_map_assoc(K, V, Pvs0, Env, L, St0),
    pat_map(As, Pvs1, Env, L, St1);
pat_map([], Pvs, _, _, St) -> {Pvs,St};
pat_map(_, Pvs, _, L, St) ->
    {Pvs,bad_form_error(L, map, St)}.

pat_map_assoc(K, V, Pvs, Env, L, St0) ->
    St1 = pat_map_key(K, Env, L, St0),
    pattern(V, Pvs, Env, L, St1).

%% pat_map_key(Key, Env, L, State) -> State.
%%  A pattern map key can currently only be a literal.

pat_map_key(Key, _, L, St) ->
    case is_pat_map_key(Key) of
        true -> St;
        false -> illegal_mapkey_error(L, Key, St)
    end.

is_pat_map_key(?Q(Lit)) -> is_literal(Lit);
is_pat_map_key([_|_]=L) ->
    lfe_lib:is_posint_list(L);                  %Literal strings only
is_pat_map_key(E) when is_atom(E) -> false;
is_pat_map_key(Lit) -> is_literal(Lit).
-else.
pat_map(Ps, Pvs, _, L, St) ->
    {Pvs,illegal_pattern_error(L, Ps, St)}.
-endif.

%% check_record_pat(Name, Fields, PatVars, Env, Line State) -> {PatVars,State}.

check_record_pat(Name, Fields, Pvs, Env, L, #lfe_lint{recs=Recs}=St)
  when is_atom(Name) ->
    case orddict:find(Name, Recs) of
        {ok,Rfields} ->
            check_record_pat_fields(Name, Fields, Rfields, Pvs, Env, L, St);
        error ->
            {Pvs,undefined_record_error(L, Name, St)}
    end;
check_record_pat(Name, _, Pvs, _, L, St) ->
    {Pvs,bad_record_error(L, Name, St)}.

check_record_pat_fields(Name, [F,Pat|Fs], Rfs, Pvs0, Env, L, St0) ->
    {Pvs1,St1} = case lists:member(F, Rfs) of
                     true ->
                         pattern(Pat, Pvs0, Env, L, St0);
                     false ->
                         {Pvs0,undefined_field_error(L, Name, F, St0)}
                 end,
    check_record_pat_fields(Name, Fs, Rfs, Pvs1, Env, L, St1);
check_record_pat_fields(_Name, [], _, Pvs, _, _, St) -> {Pvs,St};
check_record_pat_fields(Name, _, _, Pvs, _, L, St) ->
    {Pvs,bad_record_error(L, Name, St)}.

%% is_literal(Literal) -> true | false.
%% literal(Literal, Env, Line, State) -> State.
%%  Check for legal literals. We have to be extra careful here as the
%%  input can be any forms. We assume that special cases at the top
%%  level, for example atoms as variables and lists as calls, are
%%  handled before the call to literal/4.

literal(Lit, _, L, St) ->
    case is_literal(Lit) of
        true -> St;
        false -> add_error(L, {illegal_literal,Lit}, St)
    end.

is_literal(A) when is_atom(A) -> true;
is_literal(N) when is_number(N) -> true;
is_literal(B) when is_bitstring(B) -> true;
is_literal(List) when is_list(List) ->
    is_lit_list(List);
is_literal(Tup) when is_tuple(Tup) ->
    is_lit_list(tuple_to_list(Tup));
is_literal(Map) ->                              %Handles maps and non-maps
    is_lit_map(Map).

is_lit_list([Lit|Lits]) ->
    is_literal(Lit) andalso is_lit_list(Lits);
is_lit_list([]) -> true;
is_lit_list(Lit) ->
    is_literal(Lit).

-ifdef(HAS_MAPS).
is_lit_map(Map) when is_map(Map) ->
    is_lit_list(maps:to_list(Map));
is_lit_map(_) -> false.
-else.
is_lit_map(_) -> false.
-endif.

%% Functions for checking lists of forms, generate bad_form error if
%% not proper list.

foreach_form(Check, T, L, St, Fs) ->
    check_foreach(Check, fun (S) -> bad_form_error(L, T, S) end, St, Fs).

%% map_form(Check, T, L, St, Fs) ->
%%     check_map(Check, fun (S) -> bad_form_error(L, T, S) end, St, Fs).

foldl_form(Fun, T, L, Acc, St, Fs) ->
    check_foldl(Fun, fun (S) -> bad_form_error(L, T, S) end, Acc, St, Fs).

foldr_form(Fun, T, L, Acc, St, Fs) ->
    check_foldr(Fun, fun (S) -> bad_form_error(L, T, S) end, Acc, St, Fs).

%% check_foreach(Check, Err, State, Forms) -> State.
%% check_map(Check, Err, State, Forms) -> {Results,State}.
%% check_foldl(Check, Err, Acc, State, Forms) -> {Acc,State}.
%% check_foldr(Check, Err, Acc, State, Forms) -> {Acc,State}.
%%  These functions automatically manage a state variable and check for
%%  proper top list. Could easily and clearly be done with a Lisp
%%  macro.

check_foreach(Check, Err, St0, [F|Fs]) ->
    St1 = Check(F, St0),
    check_foreach(Check, Err, St1, Fs);
check_foreach(_, _, St, []) -> St;
check_foreach(_, Err, St, _) -> Err(St).

check_foldl(Check, Err, Acc0, St0, [F|Fs]) ->
    {Acc1,St1} = Check(F, Acc0, St0),
    check_foldl(Check, Err, Acc1, St1, Fs);
check_foldl(_, _, Acc, St, []) -> {Acc,St};
check_foldl(_, Err, Acc, St, _) -> {Acc,Err(St)}.

check_foldr(Check, Err, Acc0, St0, [F|Fs]) ->
    {Acc1,St1} = check_foldr(Check, Err, Acc0, St0, Fs),
    Check(F, Acc1, St1);
check_foldr(_, _, Acc, St, []) -> {Acc,St};
check_foldr(_, Err, Acc, St, _) -> {Acc,Err(St)}.

%% Versions which only check for proper top list.
%% check_foreach(Check, Err, St, Fs) ->
%%     case lfe_lib:is_proper_list(Fs) of
%%         true -> lists:foldl(Check, St, Fs);
%%         false -> Err(St)
%%     end.

%% check_map(Check, Err, St, Fs) ->
%%     case lfe_lib:is_proper_list(Fs) of
%%         true -> lists:foldl(Check, St, Fs);
%%         false -> {[],Err(St)}
%%     end.

%% check_foldl(Check, Err, Acc, St, Fs) ->
%%     case lfe_lib:is_proper_list(Fs) of
%%         true ->
%%             lists:foldl(fun (F, {A,S}) -> Check(F, A, S) end, {Acc,St}, F);
%%         false -> {Acc,Err(St)}
%%     end.

%% check_foldr(Check, Err, Acc, St, Fs) ->
%%     case lfe_lib:is_proper_list(Fs) of
%%         true ->
%%             lists:foldl(fun (F, {A,S}) -> Check(F, A, S) end, {Acc,St}, F);
%%         false -> {Acc,Err(St)}
%%     end.

%% Versions which completely wrap with a try. These may catch too much!
%% check_foreach(Fun, Err, St, Fs) ->
%%     try
%%         foldl(Fun, St, Fs)
%%     catch
%%         _:_ -> Err(St)
%%     end.

%% check_map(Fun, Err, St, Fs) ->
%%     try
%%         mapfoldl(Fun, St, Fs)
%%     catch
%%         _:_ -> {[],Err(St)}
%%     end.

%% check_foldl(Fun, Err, Acc, St, Fs) ->
%%     try
%%         foldl(fun (F, {A,S}) -> Fun(F, A, S) end, {Acc,St}, Fs)
%%     catch
%%         _:_ -> {Acc,Err(St)}
%%     end.

%% check_foldr(Fun, Err, St, Acc, Fs) ->
%%     try
%%         foldr(fun (F, {A,S}) -> Fun(F, A, S) end, {Acc,St}, Fs)
%%     catch
%%         _:_ -> {Acc,Err(St)}
%%     end.

%% safe_length(List) -> Length.
%%  Safely check length of list, can handle improper lists.

safe_length(L) -> safe_length(L, 0).

safe_length([_|L], Acc) -> safe_length(L, Acc+1);
safe_length(_, Acc) -> Acc.

%% add_error(Line, Error, State) -> State.
%% add_warning(Line, Warning, State) -> State.
%% add_errors(Line, Errors, State) -> State.

add_error(L, E, #lfe_lint{errors=Errs}=St) ->
    St#lfe_lint{errors=Errs ++ [{L,?MODULE,E}]}.

add_warning(L, W, #lfe_lint{warnings=Warns}=St) ->
    St#lfe_lint{warnings=Warns ++ [{L,?MODULE,W}]}.

%% add_errors(L, Es, #lfe_lint{errors=Errs}=St) ->
%%     St#lfe_lint{errors=Errs ++ [ {L,?MODULE,E} || E <- Es ]}.

bad_attr_error(L, A, St) ->
    add_error(L, {bad_attribute,A}, St).

bad_meta_error(L, A, St) ->
    add_error(L, {bad_meta,A}, St).

bad_form_error(L, F, St) ->
    add_error(L, {bad_form,F}, St).

bad_guard_form_error(L, F, St) ->
    add_error(L, {bad_guard_form,F}, St).

-ifdef(HAS_MAPS).
illegal_mapkey_error(L, K, St) ->
    add_error(L, {illegal_mapkey,K}, St).
-endif.

illegal_bitsize_error(L, St) ->
    add_error(L, illegal_bitsize, St).

bad_pattern_error(L, F, St) ->
    add_error(L, {bad_pattern,F}, St).

illegal_pattern_error(L, P, St) ->
    add_error(L, {illegal_pattern,P}, St).

bad_module_error(L, D, St) ->
    add_error(L, {bad_module,D}, St).

bad_record_error(L, R, St) ->
    add_error(L, {bad_record,R}, St).

bad_field_error(L, R, F, St) ->
    add_error(L, {bad_field,R,F}, St).

undefined_record_error(L, R, St) ->
    add_error(L, {undefined_record,R}, St).

undefined_field_error(L, R, F, St) ->
    add_error(L, {undefined_field,R,F}, St).

missing_field_value_error(L, R, F, St) ->
    add_error(L, {missing_field_value,R,F}, St).

bad_fdef_error(L, D, St) ->
    add_error(L, {bad_fdef,D}, St).

multi_var_error(L, V, St) ->
    add_error(L, {multi_var,V}, St).

undefined_function_error(L, F, St) ->
    add_error(L, {undefined_function,F}, St).

illegal_guard_error(L, St) ->
    add_error(L, illegal_guard, St).

bad_type_error(L, T, St) ->
    add_error(L, {bad_type,T}, St).

deprecated_error(L, D, St) ->
    add_error(L, {deprecated,D}, St).

deprecated_warning(L, D, St) ->
    add_warning(L, {deprecated,D}, St).

%% Interface to the binding functions in lfe_lib.
%% These just add arity as a dummy values as we are not interested in
%% value but it might be useful.

add_fbinding(N, A, Env) -> lfe_env:add_fbinding(N, A, A, Env).

add_vbindings(Vs, Env) ->
    foldl(fun (V, E) -> lfe_env:add_vbinding(V, dummy, E) end, Env, Vs).

%% safe_fetch(Key, Dict, Default) -> Value.

safe_fetch(Key, D, Def) ->
    case orddict:find(Key, D) of
        {ok,Val} -> Val;
        error -> Def
    end.
