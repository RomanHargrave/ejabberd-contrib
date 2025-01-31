-module(mod_pottymouth).

-behaviour(gen_mod).

-include("logger.hrl").
-include_lib("xmpp/include/xmpp.hrl").

-export([
  start/2,
  stop/1,
  on_filter_packet/1,
  mod_opt_type/1,
  mod_doc/0,
  depends/2,
  reload/3,
  mod_options/1
]).

-import(banword_gen_server, [start/0, stop/0, member/1]).
-import(nomalize_leet_gen_server, [normalize/1]).

getMessageLang(Msg) ->
  LangAttr = xmpp:get_lang(Msg),
  if
    (LangAttr /= <<>>) ->
      Lang = list_to_atom(binary_to_list(LangAttr));
    true ->
      Lang = default
  end,
  Lang.

censorWord({Lang, Word} = _MessageTerm) ->
  % we need unicode characters to normlize the word
  NormalizedWord = normalize_leet_gen_server:normalize({Lang, unicode:characters_to_list(list_to_binary(Word))}),
  % we need bytewise format for banword lookup
  IsBadWord = banword_gen_server:member({Lang, binary_to_list(unicode:characters_to_binary(NormalizedWord))}),
  if
    IsBadWord ->
      "****";
    true ->
      Word
  end.

filterWords(L) ->
  lists:map(fun censorWord/1, L).

filterMessageText(Lang, MessageText) ->
    try filterMessageText2(Lang, MessageText) of
        R ->
            R
    catch exit:{noproc,{gen_server,call,[_,_]}} ->
	?DEBUG("Blacklist of language '~p' not found, using 'default' list.", [Lang]),
	filterMessageText2(default, MessageText)
    end.

filterMessageText2(Lang, MessageText) ->
  % we want to token-ize utf8 'words'
  MessageWords = string:tokens(unicode:characters_to_list(MessageText, utf8), " "),
  MessageTerms = [{Lang, Word} || Word <- MessageWords],
  % we get back bytewise format terms (rather than utf8)
  string:join(filterWords(MessageTerms), " ").

start(_Host, Opts) ->
  Blacklists = gen_mod:get_opt(blacklists, Opts),
  lists:map(fun banword_gen_server:start/1, Blacklists),
  CharMaps = gen_mod:get_opt(charmaps, Opts),
  lists:map(fun normalize_leet_gen_server:start/1, CharMaps),
  ejabberd_hooks:add(filter_packet, global, ?MODULE, on_filter_packet, 0),
  ok.

stop(Host) ->
  Blacklists = gen_mod:get_module_opt(Host, ?MODULE, blacklists),
  banword_gen_server:stop(),
  CharMaps = gen_mod:get_module_opt(Host, ?MODULE, charmaps),
  lists:map(fun normalize_leet_gen_server:stop/1, CharMaps),
  ejabberd_hooks:delete(filter_packet, global, ?MODULE, on_filter_packet, 0),
  ok.

on_filter_packet(drop) ->
  drop;

on_filter_packet(Msg) ->
  Type = xmpp:get_type(Msg),
  if 
    (Type == chat) orelse (Type == groupchat)  ->
      BodyText = xmpp:get_text(Msg#message.body),
      if
        (BodyText /= <<>>) ->
          Lang = getMessageLang(Msg),
          FilteredMessageWords = binary:list_to_bin(filterMessageText(Lang, binary:bin_to_list(BodyText))),
          [BodyObject|_] = Msg#message.body,
          NewBodyObject = setelement(3, BodyObject, FilteredMessageWords),
          NewMsg = Msg#message{body = [NewBodyObject]},
          NewMsg;
        true ->
          Msg
      end;
    true -> 
      Msg
  end.

mod_opt_type(blacklists) -> fun (A) when is_list(A) -> A end;
mod_opt_type(charmaps) -> fun (A) when is_list(A) -> A end;
mod_opt_type(_) -> [blacklists, charmaps].
depends(_Host, _Opts) -> [].
reload(_Host, _NewOpts, _OldOpts) -> ok.
mod_options(_) ->
  [{blacklists, []},{charmaps, []}].
mod_doc() -> #{}.
