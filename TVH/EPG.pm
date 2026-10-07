package Plugins::TVH::EPG;

# Live "now playing" information for TVHeadend radio streams, taken from the
# TVHeadend EPG.
#
# Registered as a Slim::Formats::RemoteMetadata provider for
# .../stream/channel/<uuid> URLs, so playback is completely unchanged; this only
# adds metadata:
#   title  = current programme
#   artist = station name
#   album  = programme times and what's on next
#   cover  = station logo
#
# When a programme ends the EPG is re-read and LMS is told the metadata has
# changed, so player screens and JSON-RPC clients update by themselves.

use strict;

use Slim::Utils::Log;
use Slim::Utils::Timers;
use Slim::Control::Request;

use Plugins::TVH::API;
use Plugins::TVH::Prefs;

my $log = logger('plugin.TVH');

use constant DEFAULT_ICON => 'plugins/TVH/html/images/radio.png';
use constant EPG_MAX_AGE  => 120;  # seconds before the EPG is re-checked anyway
use constant EPG_RETRY    => 60;   # seconds to wait after a failed/empty lookup

# Channel info (name, icon, number) keyed by channel uuid. Filled when browsing,
# or looked up the first time a channel is played (e.g. from a favourite).
my %channels;

# EPG cache keyed by channel uuid: { now => {...}, next => {...}, fetched => time }
my %epg;
my %inFlight;

sub setChannelInfo {
	my ($class, $uuid, $info) = @_;
	$channels{$uuid} = $info if $uuid && $info;
}

sub uuidFromUrl {
	my ($class, $url) = @_;
	my ($uuid) = ($url || '') =~ m{/stream/channel/([^/?#]+)};
	return $uuid;
}

sub streamUrlFor {
	my ($class, $uuid) = @_;
	return Plugins::TVH::Prefs::getApiUrl() . 'stream/channel/' . $uuid . Plugins::TVH::Prefs::getProfile();
}

# Entry point for Slim::Formats::RemoteMetadata
sub metadataProvider {
	my ($client, $url) = @_;
	return __PACKAGE__->getMetadata($client, $url);
}

sub getMetadata {
	my ($class, $client, $url) = @_;

	my $uuid = $class->uuidFromUrl($url);
	return {} unless $uuid;

	my $info    = $channels{$uuid} || {};
	my $station = $info->{name} || 'TVHeadend Radio';
	my $icon    = $info->{icon} || DEFAULT_ICON;

	my $cached = $epg{$uuid};
	my $now    = time();

	# Refresh if we have nothing, the programme has ended, or the data is stale
	if ( !$cached
		|| ($cached->{now} && $cached->{now}->{stop} && $cached->{now}->{stop} <= $now)
		|| ($now - ($cached->{fetched} || 0)) > EPG_MAX_AGE )
	{
		$class->_fetchEpg($uuid, $url);
	}

	my $meta = {
		artist => $station,
		title  => $station,
		cover  => $icon,
		icon   => $icon,
		type   => 'TVHeadend',
	};

	if ($cached && (my $prog = $cached->{now})) {
		$meta->{title} = $prog->{title} if $prog->{title};

		my @album;
		push @album, _hhmm($prog->{start}) . '-' . _hhmm($prog->{stop}) if $prog->{start} && $prog->{stop};
		if (my $next = $cached->{next}) {
			push @album, 'Next: ' . $next->{title} . ($next->{start} ? ' (' . _hhmm($next->{start}) . ')' : '');
		}
		$meta->{album} = join('  |  ', @album) if @album;

		# Extra fields some UIs (Material, JSON-RPC clients) display
		my $desc = $prog->{subtitle} || $prog->{summary} || $prog->{description};
		$meta->{comment}      = $desc if $desc;
		$meta->{remote_title} = $meta->{title};
	}

	return $meta;
}

sub _hhmm {
	my @t = localtime(shift);
	return sprintf('%02d:%02d', $t[2], $t[1]);
}

sub _fetchEpg {
	my ($class, $uuid, $url) = @_;

	return if $inFlight{$uuid};
	$inFlight{$uuid} = 1;

	my $doFetch = sub {
		Plugins::TVH::API->getEpgForChannel(sub {
			my ($events) = @_;
			delete $inFlight{$uuid};

			my $now = time();
			my ($current, $next);

			if (ref $events eq 'ARRAY') {
				my @sorted = sort { ($a->{start} || 0) <=> ($b->{start} || 0) } @$events;
				for my $e (@sorted) {
					next unless $e->{start} && $e->{stop};
					if (!$current && $e->{start} <= $now && $e->{stop} > $now) {
						$current = $e;
					}
					elsif ($e->{start} > $now && !$next) {
						$next = $e;
					}
				}
			}
			else {
				$log->warn("EPG lookup failed for $uuid");
			}

			my $old = $epg{$uuid};
			$epg{$uuid} = {
				now     => $current,
				next    => $next,
				# if nothing came back, retry sooner rather than on every poll
				fetched => ($current ? $now : $now - EPG_MAX_AGE + EPG_RETRY),
			};

			my $changed = !$old
				|| (($old->{now}  && $old->{now}->{eventId})  || '') ne (($current && $current->{eventId}) || '')
				|| (($old->{next} && $old->{next}->{eventId}) || '') ne (($next    && $next->{eventId})    || '');

			$class->_notify($url) if $changed;

			# Wake up a few seconds after this programme ends
			if ($current && $current->{stop}) {
				Slim::Utils::Timers::killTimers($uuid, \&_programmeEnded);
				Slim::Utils::Timers::setTimer($uuid, $current->{stop} + 5, \&_programmeEnded, $class, $url);
			}
		}, $uuid);
	};

	# Make sure we know the station name/logo (e.g. when played from a favourite)
	if (!$channels{$uuid}) {
		Plugins::TVH::API->getStations(sub {
			my ($stations) = @_;
			if (ref $stations eq 'ARRAY') {
				for my $s (@$stations) {
					next unless $s->{uuid};
					$channels{ $s->{uuid} } ||= {
						name   => $s->{name},
						number => $s->{number},
						icon   => Plugins::TVH::Plugin::_getStationImage($s->{icon_public_url}),
					};
				}
			}
			$doFetch->();
		});
	}
	else {
		$doFetch->();
	}
}

sub _programmeEnded {
	my ($uuid, $class, $url) = @_;

	# Only bother if someone is still listening to this channel
	return unless _clientsPlaying($url);

	delete $epg{$uuid}->{fetched} if $epg{$uuid};
	$class->_fetchEpg($uuid, $url);
}

sub _clientsPlaying {
	my ($url) = @_;
	my @clients;
	for my $client (Slim::Player::Client::clients()) {
		my $song = $client->playingSong() or next;
		next unless $song->track && $song->track->url eq $url;
		push @clients, $client;
	}
	return @clients;
}

sub _notify {
	my ($class, $url) = @_;
	for my $client (_clientsPlaying($url)) {
		main::INFOLOG && $log->is_info && $log->info('New programme metadata for ' . $client->name);
		Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
	}
}

1;
