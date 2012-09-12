#!/usr/bin/env perl
use strict;
use warnings;
use utf8;
use 5.010000;
use autodie;
use Web::Query;
use LWP::UserAgent;
use XML::Feed;
use JSON::XS;
use Text::MicroTemplate qw/render_mt encoded_string/;
use Log::Minimal;
use HTTP::Date;
use Getopt::Long;
use XMLRPC::Lite;
use Algorithm::Diff qw/diff/;

my $ua = LWP::UserAgent->new(timeout => 15);
$ua->ssl_opts(verify_hostname => 0);
$Web::Query::UserAgent = $ua;

my $MAX_ENTRIES = 30;
GetOptions(
    'n=i' => \$MAX_ENTRIES,
);

my $ofname = shift || 'npmrss.rss';

&main;exit;

sub main {
    infof("Get project links");
    my @projects = get_project_list();
       @projects = @projects[0..$MAX_ENTRIES-1] if @projects > $MAX_ENTRIES;

    infof("Extract entries");
    my @entries = extract_entries(@projects);

    infof("Output rss");
    output_rss($ofname, \@entries);

    infof("Sending pings");
    send_pings();
}

sub get_project_list {
    my @projects = @{wq('https://npmjs.org/browse/updated')
                        ->find('.row p a')
                        ->map(sub { $_->text })};
    return @projects;
}

sub extract_entries {
    my @projects = @_;

    my @entries;
    my $i = 0;
    for my $project (@projects) {
        infof("  Extracting $project(%d/%d)", $i++, 0+@projects);
        my $res = $ua->get("https://registry.npmjs.org/$project");
        unless ($res->is_success) {
            warnf("Cannot get a information for $project: %s", $res->status_line);
            next;
        }
        my $data = decode_json($res->content);
        my %time = %{$data->{time}};
        my @versions = (
            map { $_->[0] }
            reverse
            sort { $a->[1] <=> $b->[1] }
            map { [$_, str2time($time{$_})] }
            keys %time
        );
        my $diff;
        if (@versions >= 2) {
            my $rd0 = $data->{versions}->{$versions[0]}->{readme};
            my $rd1 = $data->{versions}->{$versions[1]}->{readme};
            if ($rd0 && $rd1) {
                my $dsrc = diff [split /\n/, $rd1], [split /\n/, $rd0];
                $diff = join("\n", map { $_->[2] } grep { $_->[0] eq '+' } @{$dsrc->[0]});
            }
        }
        my $latest = $data->{versions}->{$data->{'dist-tags'}->{'latest'}};
        my $title = sprintf '%s-%s', $latest->{name}, $latest->{version};
        my $html = render_mt(<<'...', $data, $latest, $diff);
? my $n = $_[0];
? my $latest = $_[1];
? my $diff = $_[2];
? use Gravatar::URL;
? if ($latest->{description}) {
<div class="description"><?= $latest->{description} ?></div>
? }
? for my $maintainer (@{$n->{maintainers} || []}) {
<img src="<?= eval { gravatar_url(email => $maintainer->{email}, size => 40) } || '' ?>"> <?= $maintainer->{name} ?><br />
? }
? if ($diff) {
    <pre><?= $diff ?></pre>
? }
<table>
? if ($latest->{dependencies}) {
<tr>
<th>Dependencies</th><td><?= ddf $latest->{dependencies} ?></td>
</tr>
? }
? if ($latest->{keywords}) {
<tr>
<th>Keywords</th><td><?= ddf($latest->{keywords}) || '' ?></td>
</tr>
? }
</tr>
</table>
...
        push @entries, +{
            title => $title,
            html => $html,
            link => 'https://npmjs.org/package/' . $latest->{name},
        };
    }
    return @entries;
}

sub output_rss {
    my ($ofname, $entries) = @_;
    my $feed = XML::Feed->new('RSS', version => '2.0');
    $feed->title('NPM Recent Feed');
    $feed->link('http://64p.org/npmrss.rss');
    $feed->description('rich recent packages feed');
    for my $entry (@$entries) {
        my $e = XML::Feed::Entry->new();
        $e->title($entry->{title});
        $e->link($entry->{link});
        $e->content(
            XML::Feed::Content->new({
                body => $entry->{html},
                type => 'text/html',
            })
        );
        $feed->add_entry($e);
    }
    open my $ofh, '>:utf8', $ofname;
    print $ofh $feed->as_xml;
    close $ofh;
}

sub send_pings {
    send_ping($_) for qw(
        http://rpc.reader.livedoor.com/ping
        http://www.google.com/blogsearch
    );
}
sub send_ping {
    my $ping_url = shift;
    my $result=XMLRPC::Lite
        ->proxy($ping_url)
        ->call('weblogUpdates.ping',
           "NPM RSS",
           "http://64p.org/npmrss.rss")
        ->result;
    infof("%s: %s", $ping_url, eval { $result->{'message'} });
}
