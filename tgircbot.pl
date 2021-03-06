#!/usr/bin/env perl
use v5.18;
use strict;
use warnings;

use List::Util qw(max);
use Getopt::Long qw(GetOptions);
use Mojo::JSON qw(decode_json);
use Mojo::IOLoop;
use Mojo::Util;
use Mojo::IRC;
use Mojo::IRC::UA;
use IRC::Utils ();

use WWW::Telegram::BotAPI;
my $CONTEXT = {};

sub message_from_tg_to_irc {
    state $last_sent_text = "";

    my $channel = $CONTEXT->{irc_channel} or return;
    my $irc = $CONTEXT->{irc_bot} or return;

    my ($tg_message) = @_;

    if ($tg_message->{text} && $tg_message->{text} ne "") {
        my @lines = grep { ! /^\s+$/ } split /\n+/, $tg_message->{text};
        for my $line (@lines) {
            my $from_name = $tg_message->{from}{username} // $tg_message->{from}{first_name};
            my $text = '<' . $from_name . '> ';

            if ($tg_message->{reply_to_message}) {
                my $x = $tg_message->{reply_to_message}{from};

                my $n;
                if ($CONTEXT->{telegram_bot_id} eq $x->{id} && ($tg_message->{reply_to_message}{text} =~ m/\A ( <([^<>]+)> ) \s /x)) {
                    $n = $2;
                }

                $n //= $x->{username} // $x->{first_name};

                $text .= $n . ": ";
            }
            $text .= $line;
            if ($last_sent_text ne $text) {
                $last_sent_text = $text;
                $irc->write(PRIVMSG => $channel, ":$text\n", sub {});
                sleep(1);
            }
        }
    } else {
        say "text-less message: " . Mojo::Util::dumper( $tg_message );
    }
}

sub message_from_irc_to_tg {
    state $last_sent_text = "";

    my $chat_id = $CONTEXT->{telegram_group_chat_id} or return;
    my $tg = $CONTEXT->{tg_bot} or return;

    my ($irc_message) = @_;

    my $text = $irc_message->{text};
    my $from = $irc_message->{from};
    if ($from =~ /^slackbot/) {
        $from = "";
        if ($text =~ s/\A ( <([a-zA-Z0-9_]+?)> ) \s //x) {
            my $real_nick = $2;
            $text = "<\x{24e2}${real_nick}> $text";
        }
    } elsif ($from =~ /^g0v-bridge/) {
        $from = "";
        if ($text =~ s/\A ( (.+?) \@ slack-legacy ) : \s //x) {
            my $real_nick = $2;
            $text = "<\x{24e2}${real_nick}> $text";
        }
    } else {
        $from = "<$from> ";
    }

    my $tg_text = join('', $from, $text);
    return if $last_sent_text eq $tg_text;
    $last_sent_text = $tg_text;
    $tg->api_request(
	sendMessage => {
	    chat_id => $chat_id,
	    text    => $tg_text,
	}, sub {
	    my ($ua, $tx) = @_;
	    unless ($tx->success) {
		say "sendMessage failed";
	    }
	});
}

sub tg_get_updates {
    return unless $CONTEXT->{tg_bot} && $CONTEXT->{telegram_group_chat_id};
    state $max_update_id = -2;

    $CONTEXT->{tg_bot}->api_request(
        'getUpdates',
        { offset => ($max_update_id+1), timeout => 5 },
        sub {
            my ($ua, $tx) = @_;
            if ($tx->success) {
                my $res = $tx->res->json;
                for (@{$res->{result}}) {
                    $max_update_id = max($max_update_id, $_->{update_id});
                    if ($CONTEXT->{telegram_group_chat_id} == $_->{message}{chat}{id}) {
                        message_from_tg_to_irc($_->{message});
                    } else {
                        say "Unknown chat_id: " . Mojo::Util::dumper($_);
                    }
                }
            } else {
                say "getUpdates failed: " . Mojo::Util::dumper( $tx->error );
            }
        }
    );
}

sub tg_init {
    my ($token) = @_;
    my $tgbot = WWW::Telegram::BotAPI->new( token => $token, async => 1 );
    if ($tgbot->agent->can("inactivity_timeout")) {
        $tgbot->agent->inactivity_timeout(180);
    }

    my $get_me_cb;
    $get_me_cb = sub  {
        my ($ua, $tx) = @_;
        if ($tx->success) {
            my $r = $tx->res->json;
            Mojo::Util::dumper(['getMe', $r]);
            Mojo::IOLoop->recurring( 15, \&tg_get_updates );
        } else {
            Mojo::Util::dumper(['getMe Failed.', $tx->res->body]);
            Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });
        }
    };
    Mojo::IOLoop->timer( 5 => sub { $tgbot->api_request(getMe => $get_me_cb) });

    return $tgbot;
}

sub irc_init {
    my ($nick, $server, $channel) = @_;
    my $irc;

    $irc = Mojo::IRC::UA->new(
        nick => $nick,
        user => $nick,
        server => $server,
    );
    $irc->op_timeout(120);
    $irc->register_default_event_handlers;

    $irc->on(
        irc_join => sub {
            my($self, $message) = @_;
        });

    $irc->on(
        irc_privmsg => sub {
            my($self, $message) = @_;
	    my ($c, $text) = @{ $message->{params} };
	    return unless $c eq $channel;

	    my $from_nick = IRC::Utils::parse_user($message->{prefix});
	    message_from_irc_to_tg({ from => $from_nick, text => $text });
        });

    $irc->on(
        irc_rpl_welcome => sub {
            say "-- connected";
            $irc->join_channel(
                $channel,
                sub {
                    my ($self, $err, $info) = @_;
                    say "-- join $channel -- topic - $info->{topic}";
                }
            );
        });

    $irc->on(error => sub {
                 my ($self, $message) = @_;
                 Mojo::IOLoop->timer( 10 => sub { $irc->connect(sub{}) } );
             });
    $irc->connect(sub {});

    return $irc;
}

sub MAIN {
    my (%args) = @_;

    $CONTEXT->{irc_server} = $args{irc_server};
    $CONTEXT->{irc_nickname} = $args{irc_nickname};
    $CONTEXT->{irc_channel} = $args{irc_channel};
    $CONTEXT->{telegram_group_chat_id} = $args{telegram_group_chat_id};

    $CONTEXT->{telegram_bot_id}  = substr($args{telegram_token}, 0, index($args{telegram_token}, ":"));

    $CONTEXT->{tg_bot}  = tg_init( $args{telegram_token} );
    $CONTEXT->{irc_bot} = irc_init($args{irc_nickname}, $args{irc_server}, $args{irc_channel});

    Mojo::IOLoop->start;
}

my %args;
GetOptions(
    \%args,
    "irc_nickname=s",
    "irc_server=s",
    "irc_channel=s",
    "telegram_token=s",
    "telegram_group_chat_id=s",
);
MAIN(%args);
