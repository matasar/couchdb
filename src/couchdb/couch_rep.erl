% Licensed under the Apache License, Version 2.0 (the "License"); you may not
% use this file except in compliance with the License.  You may obtain a copy of
% the License at
%
%   http://www.apache.org/licenses/LICENSE-2.0
%
% Unless required by applicable law or agreed to in writing, software
% distributed under the License is distributed on an "AS IS" BASIS, WITHOUT
% WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.  See the
% License for the specific language governing permissions and limitations under
% the License.

-module(couch_rep).

-include("couch_db.hrl").

-record(http_db, {
    uri,
    headers
}).

-record(rep_stats, {
    docs_checked=0,
    docs_missing=0,
    docs_read=0,
    docs_written=0,
    doc_write_failures=0
}).
    
-export([replicate/2, replicate/3]).


url_encode(Bin) when is_binary(Bin) ->
    url_encode(binary_to_list(Bin));
url_encode([H|T]) ->
    if
    H >= $a, $z >= H ->
        [H|url_encode(T)];
    H >= $A, $Z >= H ->
        [H|url_encode(T)];
    H >= $0, $9 >= H ->
        [H|url_encode(T)];
    H == $_; H == $.; H == $-; H == $: ->
        [H|url_encode(T)];
    true ->
        case lists:flatten(io_lib:format("~.16.0B", [H])) of
        [X, Y] ->
            [$%, X, Y | url_encode(T)];
        [X] ->
            [$%, $0, X | url_encode(T)]
        end
    end;
url_encode([]) ->
    [].


replicate(DbNameA, DbNameB) ->
    replicate(DbNameA, DbNameB, []).

replicate(Source, Target, Options) ->
    {ok, DbSrc} = open_db(Source),
    try
        {ok, DbTgt} = open_db(Target),
        try
            replicate2(Source, DbSrc, Target, DbTgt, Options)
        after
            close_db(DbTgt)
        end        
    after
        close_db(DbSrc)
    end.
    
replicate2(Source, DbSrc, Target, DbTgt, Options) ->
    {ok, HostName} = inet:gethostname(),
    RepRecordNameDigest = couch_util:to_hex(
            erlang:md5(term_to_binary([HostName, Source, Target]))),
    RepRecKey = ?l2b(?LOCAL_DOC_PREFIX ++ RepRecordNameDigest),
    
    ReplicationStartTime = httpd_util:rfc1123_date(),
    
    {ok, InfoSrc} = get_db_info(DbSrc),
    {ok, InfoTgt} = get_db_info(DbTgt),
    
    SrcInstanceStartTime = proplists:get_value(instance_start_time, InfoSrc),
    TgtInstanceStartTime = proplists:get_value(instance_start_time, InfoTgt),
    
    RepRecDocSrc =
    case open_doc(DbSrc, RepRecKey, []) of
    {ok, SrcDoc} ->
        ?LOG_DEBUG("Found existing replication record on source", []),
        SrcDoc;
    _ -> #doc{id=RepRecKey}
    end,

    RepRecDocTgt =
    case open_doc(DbTgt, RepRecKey, []) of
    {ok, TgtDoc} ->
        ?LOG_DEBUG("Found existing replication record on target", []),
        TgtDoc;
    _ -> #doc{id=RepRecKey}
    end,
    

    #doc{body={RepRecProps}} = RepRecDocSrc,
    #doc{body={RepRecPropsTgt}} = RepRecDocTgt,

    
    case proplists:get_value(<<"session_id">>, RepRecProps) == 
            proplists:get_value(<<"session_id">>, RepRecPropsTgt) of
    true ->
        % if the records have the same session id,
        % then we have a valid replication history
        OldSeqNum = proplists:get_value(<<"source_last_seq">>, RepRecProps, 0),
        OldHistory = proplists:get_value(<<"history">>, RepRecProps, []);
    false ->
        ?LOG_INFO("Replication records differ. "
                "Performing full replication instead of incremental.", []),
        ?LOG_DEBUG("Record on source:~p~nRecord on target:~p~n",
                [RepRecProps, RepRecPropsTgt]),
        OldSeqNum = 0,
        OldHistory = []
    end,
    
    
    case proplists:get_value(full, Options, false) of
    true  -> StartSeqNum = 0;
    false -> StartSeqNum = OldSeqNum
    end,

    {NewSeqNum, Stats} = pull_rep(DbTgt, DbSrc, StartSeqNum),    
    
    case NewSeqNum == StartSeqNum andalso StartSeqNum > 0 of
    true ->
        % nothing changed, don't record any results
        {ok, {[{<<"no_changes">>, true} | RepRecProps]}};
    false ->
        % something changed, record results for incremental replication,
        
        % commit changes to both src and tgt. The src because if changes
        % we replicated are lost, we'll record the a seq number ahead 
        % of what was committed. If those changes are lost and the seq number
        % reverts to a previous committed value, we will lose future changes
        % when new doc updates are given our already replicated seq nums.
        
        % commit the src async
        ParentPid = self(),
        SrcCommitPid = spawn_link(fun() -> 
                ParentPid ! {self(), ensure_full_commit(DbSrc)} end),
                
        % commit tgt sync
        {ok, TgtInstanceStartTime2} = ensure_full_commit(DbTgt),
        
        receive {SrcCommitPid, {ok, SrcInstanceStartTime2}} -> ok end,
        
        RecordSeqNum =
        if SrcInstanceStartTime2 == SrcInstanceStartTime andalso
                TgtInstanceStartTime2 == TgtInstanceStartTime ->
            NewSeqNum;
        true ->
            ?LOG_INFO("A server has restarted sinced replication start. "
                "Not recording the new sequence number to ensure the "
                "replication is redone and documents reexamined.", []),
            StartSeqNum
        end,
        % convert the stats record into a proplist and then to json
        [rep_stats | StatsList] = tuple_to_list(Stats),
        StatFieldNames =
                [?l2b(atom_to_list(T)) || T <- record_info(fields, rep_stats)],
        StatProps = lists:zip(StatFieldNames, StatsList),
        
        NewHistoryEntry = {
                [{<<"start_time">>, list_to_binary(ReplicationStartTime)},
                {<<"end_time">>, list_to_binary(httpd_util:rfc1123_date())},
                {<<"start_last_seq">>, StartSeqNum},
                {<<"end_last_seq">>, NewSeqNum} | StatProps]},
        % limit history to 50 entries
        HistEntries =lists:sublist([NewHistoryEntry |  OldHistory], 50),
        NewRepHistory =
                {[{<<"session_id">>, couch_util:new_uuid()},
                  {<<"source_last_seq">>, RecordSeqNum},
                  {<<"history">>, HistEntries}]},

        {ok, _} = update_doc(DbSrc, RepRecDocSrc#doc{body=NewRepHistory}, []),
        {ok, _} = update_doc(DbTgt, RepRecDocTgt#doc{body=NewRepHistory}, []),
        {ok, NewRepHistory}
    end.

pull_rep(DbTarget, DbSource, SourceSeqNum) ->
    {ok, {NewSeq, Stats}} = 
        enum_docs_since(DbSource, DbTarget, SourceSeqNum, {SourceSeqNum, #rep_stats{}}),
    {NewSeq, Stats}.

do_http_request(Url, Action, Headers) ->
    do_http_request(Url, Action, Headers, []).

do_http_request(Url, Action, Headers, JsonBody) ->
    do_http_request(Url, Action, Headers, JsonBody, 10).

do_http_request(Url, Action, _Headers, _JsonBody, 0) ->
    ?LOG_ERROR("couch_rep HTTP ~p request failed after 10 retries: ~p", 
        [Action, Url]);
do_http_request(Url, Action, Headers, JsonBody, Retries) ->
    ?LOG_DEBUG("couch_rep HTTP ~p request: ~p", [Action, Url]),
    Body =
    case JsonBody of
    [] ->
        <<>>;
    _ ->
        iolist_to_binary(?JSON_ENCODE(JsonBody))
    end,
    Options = case Action of
        get -> [];
        _ -> [{transfer_encoding, {chunked, 65535}}]
    end ++ [
        {content_type, "application/json; charset=utf-8"},
        {max_pipeline_size, 101}
    ],
    case ibrowse:send_req(Url, Headers, Action, Body, Options) of
    {ok, Status, ResponseHeaders, ResponseBody} ->
        ResponseCode = list_to_integer(Status),
        if
        ResponseCode >= 200, ResponseCode < 300 ->
            ?JSON_DECODE(ResponseBody);
        ResponseCode >= 300, ResponseCode < 400 ->
            RedirectUrl = mochiweb_headers:get_value("Location", 
                mochiweb_headers:make(ResponseHeaders)),
            do_http_request(RedirectUrl, Action, Headers, JsonBody, Retries-1);
        ResponseCode >= 400, ResponseCode < 500 -> 
            ?JSON_DECODE(ResponseBody);        
        ResponseCode == 500 ->
            ?LOG_INFO("retrying couch_rep HTTP ~p request due to 500 error: ~p",
                [Action, Url]),
            do_http_request(Url, Action, Headers, JsonBody, Retries - 1)
        end;
    {error, Reason} ->
        ?LOG_INFO("retrying couch_rep HTTP ~p request due to {error, ~p}: ~p", 
            [Action, Reason, Url]),
        do_http_request(Url, Action, Headers, JsonBody, Retries - 1)
    end.

save_docs_buffer(DbTarget, DocsBuffer, [], Stats) ->
    receive
    {Src, shutdown} ->
        Stats2 = save_docs_with_stats(DbTarget, DocsBuffer, Stats),
        Src ! {done, self(), Stats2}
    end;
save_docs_buffer(DbTarget, DocsBuffer, UpdateSequences, Stats) ->
    [NextSeq|Rest] = UpdateSequences,
    receive
    {Src, skip, NextSeq} ->
        Src ! got_it,
        save_docs_buffer(DbTarget, DocsBuffer, Rest, Stats);
    {Src, docs, {NextSeq, Docs}} ->
        Src ! got_it,
        case couch_util:should_flush() of
            true ->
                Stats2 =
                    save_docs_with_stats(DbTarget, Docs++DocsBuffer, Stats),
                save_docs_buffer(DbTarget, [], Rest, Stats2);
            false ->
                save_docs_buffer(DbTarget, Docs++DocsBuffer, Rest, Stats)
        end;
    {Src, shutdown} ->
        ?LOG_ERROR("received shutdown while waiting for more update_seqs", []),
        Stats2 = save_docs_with_stats(DbTarget,DocsBuffer,Stats),
        Src ! {done, self(), Stats2}
    end.

save_docs_with_stats(Db, Docs, Stats) ->
   {ok, Errors} = update_docs(Db, Docs, [], replicated_changes),
    dump_update_errors(Errors),
    Stats#rep_stats{
        docs_written=Stats#rep_stats.docs_written+length(Docs)-length(Errors),
        doc_write_failures=Stats#rep_stats.doc_write_failures+length(Errors)}.

% we should probably write these to a special replication log
% or have a callback where the caller decides what to do with replication
% errors.
dump_update_errors([]) -> ok;
dump_update_errors([{{Id, Rev}, Error}|Rest]) ->
    ?LOG_INFO("error replicating document \"~s\" rev \"~s\":~p",
        [Id, couch_doc:rev_to_str(Rev), Error]),
    dump_update_errors(Rest).


pmap(F,List) ->
    [wait_result(Worker) || Worker <- [spawn_worker(self(),F,E) || E <- List]].

spawn_worker(Parent, F, E) ->
    erlang:spawn_monitor(fun() -> Parent ! {self(), F(E)} end).

wait_result({Pid,Ref}) ->
    receive
    {'DOWN', Ref, _, _, normal} -> receive {Pid,Result} -> Result end;
    {'DOWN', Ref, _, _, Reason} -> exit(Reason)
end.

enum_docs_parallel(DbS, DbT, InfoList) ->
    UpdateSeqs = [Seq || {_, Seq, _, _} <- InfoList],
    SaveDocsPid = spawn_link(fun() ->
            save_docs_buffer(DbT,[],UpdateSeqs, #rep_stats{}) end),
    
    ReadStatsList = pmap(fun({Id, Seq, SrcRevs, MissingRevs}) ->
        case MissingRevs of
        [] ->
            SaveDocsPid ! {self(), skip, Seq},
            receive got_it -> ok end,
            #rep_stats{docs_checked=length(SrcRevs)};
        _ ->
            {ok, DocResults} = open_doc_revs(DbS, Id, MissingRevs, [latest]),
            
            % only save successful reads
            Docs = [RevDoc || {ok, RevDoc} <- DocResults],
            
            % include update_seq so we save docs in order
            SaveDocsPid ! {self(), docs, {Seq, Docs}},
            receive got_it -> ok end,
            #rep_stats{docs_checked=length(SrcRevs),
                docs_missing=length(MissingRevs),
                docs_read=length(Docs)}
        end
    end, InfoList),
    
    SaveDocsPid ! {self(), shutdown},
    
    receive
        {done, SaveDocsPid, WriteStats} -> ok
    end,
    
    lists:foldl(
        fun(StatIn, AccStat) ->
            sum_rep_stats(StatIn, AccStat)
        end, #rep_stats{}, [WriteStats | ReadStatsList]).


sum_rep_stats(StatsA, StatsB) ->
    % Quick and dirty way to sum matchng fields of the records.
    % convert to lists
    [rep_stats | FieldsA] = tuple_to_list(StatsA),
    [rep_stats | FieldsB] = tuple_to_list(StatsB),
    % pairwise add the fields and convert back to the record
    list_to_tuple([rep_stats |
            lists:zipwith(fun(A,B) -> A + B end, FieldsA, FieldsB)]).


            
open_db({remote, Url, Headers})->
    {ok, #http_db{uri=Url, headers=Headers}};
open_db({local, DbName, UserCtx})->
    couch_db:open(DbName, [{user_ctx, UserCtx}]).

close_db(#http_db{})->
    ok;
close_db(Db)->
    couch_db:close(Db).

get_db_info(#http_db{uri=DbUrl, headers=Headers}) ->
    {DbProps} = do_http_request(DbUrl, get, Headers),
    {ok, [{list_to_existing_atom(?b2l(K)), V} || {K,V} <- DbProps]};
get_db_info(Db) ->
    couch_db:get_db_info(Db).


ensure_full_commit(#http_db{uri=DbUrl, headers=Headers}) ->
    {ResultProps} = do_http_request(DbUrl ++ "_ensure_full_commit", post, Headers, true),
    true = proplists:get_value(<<"ok">>, ResultProps),
    {ok, proplists:get_value(<<"instance_start_time">>, ResultProps)};
ensure_full_commit(Db) ->
    couch_db:ensure_full_commit(Db).
    
    
get_doc_info_list(#http_db{uri=DbUrl, headers=Headers}, StartSeq) ->
    Url = DbUrl ++ "_all_docs_by_seq?limit=100&startkey=" 
        ++ integer_to_list(StartSeq),
    {Results} = do_http_request(Url, get, Headers),
    lists:map(fun({RowInfoList}) ->
        {RowValueProps} = proplists:get_value(<<"value">>, RowInfoList),
        #doc_info{
            id=proplists:get_value(<<"id">>, RowInfoList),
            rev=couch_doc:parse_rev(proplists:get_value(<<"rev">>, RowValueProps)),
            update_seq = proplists:get_value(<<"key">>, RowInfoList),
            conflict_revs =
                couch_doc:parse_revs(proplists:get_value(<<"conflicts">>, RowValueProps, [])),
            deleted_conflict_revs =
                couch_doc:parse_revs(proplists:get_value(<<"deleted_conflicts">>, RowValueProps, [])),
            deleted = proplists:get_value(<<"deleted">>, RowValueProps, false)
        }
    end, proplists:get_value(<<"rows">>, Results));
get_doc_info_list(DbSource, StartSeq) ->
    {ok, {_Count, DocInfoList}} = couch_db:enum_docs_since(DbSource, StartSeq, 
    fun (_, _, {100, DocInfoList}) ->
            {stop, {100, DocInfoList}};
        (DocInfo, _, {Count, DocInfoList}) -> 
            {ok, {Count+1, [DocInfo|DocInfoList]}} 
    end, {0, []}),
    lists:reverse(DocInfoList).

enum_docs_since(DbSource, DbTarget, StartSeq, {AccLastSeq, AccStats}) ->
    DocInfoList = get_doc_info_list(DbSource, StartSeq),
    case DocInfoList of
    [] ->
        {ok, {AccLastSeq, AccStats}};
    _ ->
        UpdateSeqs = [D#doc_info.update_seq || D <- DocInfoList],
        SrcRevsList = lists:map(fun(SrcDocInfo) ->
            #doc_info{id=Id,
                rev=Rev,
                conflict_revs=Conflicts,
                deleted_conflict_revs=DelConflicts
            } = SrcDocInfo,
            SrcRevs = [Rev | Conflicts] ++ DelConflicts,
            {Id, SrcRevs}
        end, DocInfoList),        
        {ok, MissingRevsList} = get_missing_revs(DbTarget, SrcRevsList),
        InfoList = lists:map(fun({{Id, SrcRevs}, Seq}) ->
            MissingRevs = proplists:get_value(Id, MissingRevsList, []),
            {Id, Seq, SrcRevs, MissingRevs}
        end, lists:zip(SrcRevsList, UpdateSeqs)),
        Stats = enum_docs_parallel(DbSource, DbTarget, InfoList),
        TotalStats = sum_rep_stats(Stats, AccStats),
        
        #doc_info{update_seq=LastSeq} = lists:last(DocInfoList),
        enum_docs_since(DbSource, DbTarget, LastSeq, {LastSeq, TotalStats})
    end.

get_missing_revs(#http_db{uri=DbUrl, headers=Headers}, DocIdRevsList) ->
    DocIdRevsList2 = [{Id, couch_doc:rev_to_strs(Revs)} || {Id, Revs} <- DocIdRevsList],
    {ResponseMembers} = do_http_request(DbUrl ++ "_missing_revs", post, Headers,
            {DocIdRevsList2}),
    {DocMissingRevsList} = proplists:get_value(<<"missing_revs">>, ResponseMembers),
    DocMissingRevsList2 = [{Id, couch_doc:parse_revs(MissingRevStrs)} || {Id, MissingRevStrs} <- DocMissingRevsList],
    {ok, DocMissingRevsList2};
get_missing_revs(Db, DocId) ->
    couch_db:get_missing_revs(Db, DocId).


update_doc(#http_db{uri=DbUrl, headers=Headers}, #doc{id=DocId}=Doc, Options) ->
    [] = Options,
    Url = DbUrl ++ url_encode(DocId),
    {ResponseMembers} = do_http_request(Url, put, Headers,
            couch_doc:to_json_obj(Doc, [revs,attachments])),
    Rev = proplists:get_value(<<"rev">>, ResponseMembers),
    {ok, couch_doc:parse_rev(Rev)};
update_doc(Db, Doc, Options) ->
    couch_db:update_doc(Db, Doc, Options).

update_docs(_, [], _, _) ->
    {ok, []};
update_docs(#http_db{uri=DbUrl, headers=Headers}, Docs, [], replicated_changes) ->
    JsonDocs = [couch_doc:to_json_obj(Doc, [revs,attachments]) || Doc <- Docs],
    ErrorsJson =
        do_http_request(DbUrl ++ "_bulk_docs", post, Headers,
                {[{new_edits, false}, {docs, JsonDocs}]}),
    ErrorsList =
    lists:map(
        fun({Props}) ->
            Id = proplists:get_value(<<"id">>, Props),
            Rev = couch_doc:parse_rev(proplists:get_value(<<"rev">>, Props)),
            ErrId = couch_util:to_existing_atom(
                    proplists:get_value(<<"error">>, Props)),
            Reason = proplists:get_value(<<"reason">>, Props),
            Error = {ErrId, Reason},
            {{Id, Rev}, Error}
        end, ErrorsJson),
    {ok, ErrorsList};
update_docs(Db, Docs, Options, UpdateType) ->
    couch_db:update_docs(Db, Docs, Options, UpdateType).


open_doc(#http_db{uri=DbUrl, headers=Headers}, DocId, Options) ->
    [] = Options,
    case do_http_request(DbUrl ++ url_encode(DocId), get, Headers) of
    {[{<<"error">>, ErrId}, {<<"reason">>, Reason}]} ->
        {couch_util:to_existing_atom(ErrId), Reason};
    Doc  ->
        {ok, couch_doc:from_json_obj(Doc)}
    end;
open_doc(Db, DocId, Options) ->
    couch_db:open_doc(Db, DocId, Options).


open_doc_revs(#http_db{uri=DbUrl, headers=Headers}, DocId, Revs0, Options) ->
    Revs = couch_doc:rev_to_strs(Revs0),
    QueryOptionStrs =
    lists:map(fun(latest) ->
            % latest is only option right now
            "latest=true"
        end, Options),
    
    BaseUrl = DbUrl ++ url_encode(DocId) ++ "?" ++ couch_util:implode(
        ["revs=true", "attachments=true"] ++ QueryOptionStrs, "&"),
    
    %% MochiWeb expects URLs < 8KB long, so maybe split into multiple requests
    MaxN = trunc((8192 - length(BaseUrl))/14),
    
    JsonResults = case length(Revs) > MaxN of
    false ->
        Url = BaseUrl ++ "&open_revs=" ++ lists:flatten(?JSON_ENCODE(Revs)),
        do_http_request(Url, get, Headers);
    true ->
        {_, Rest, Acc} = lists:foldl(
        fun(Rev, {Count, RevsAcc, AccResults}) when Count =:= MaxN ->
            QSRevs = lists:flatten(?JSON_ENCODE(lists:reverse(RevsAcc))),
            Url = BaseUrl ++ "&open_revs=" ++ QSRevs,
            {1, [Rev], AccResults++do_http_request(Url, get, Headers)};
        (Rev, {Count, RevsAcc, AccResults}) ->
            {Count+1, [Rev|RevsAcc], AccResults}
        end, {0, [], []}, Revs),
        Acc ++ do_http_request(BaseUrl ++ "&open_revs=" ++ 
            lists:flatten(?JSON_ENCODE(lists:reverse(Rest))), get, Headers)
    end,
    
    Results =
    lists:map(
        fun({[{<<"missing">>, Rev}]}) ->
            {{not_found, missing}, couch_doc:parse_rev(Rev)};
        ({[{<<"ok">>, JsonDoc}]}) ->
            {ok, couch_doc:from_json_obj(JsonDoc)}
        end, JsonResults),
    {ok, Results};
open_doc_revs(Db, DocId, Revs, Options) ->
    couch_db:open_doc_revs(Db, DocId, Revs, Options).


