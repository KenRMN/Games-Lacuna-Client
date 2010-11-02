package Games::Lacuna::Client::Governor;
use strict;
use warnings;
no warnings 'uninitialized'; # Yes, I count on undef to be zero.  Cue admonishments.

use Games::Lacuna::Client::PrettyPrint qw(trace message warning action);
use List::Util qw(sum max min);
use List::MoreUtils qw(any part);
use Hash::Merge qw(merge);
use JSON qw(to_json from_json);

use Data::Dumper;

sub new {
    my ($self, $client, $config_file) = @_;

    open my $fh, '<', $config_file or die "Couldn't open $config_file";
    my $config = YAML::Any::Load( do { local $/; <$fh> } );
    close $fh;

    return bless {
        client => $client,
        config => $config,
    },$self;
}

sub run {
    my $self = shift;
    my $refresh_cache = shift;
    my $client = $self->{client};
    my $config = $self->{config};

    my $data = $client->empire->view_species_stats();
    $self->{status} = $data->{status};
    my $planets        = $self->{status}->{empire}->{planets};
    my $home_planet_id = $self->{status}->{empire}->{home_planet_id}; 

    my $do_keepalive = 1;
    my $start_time = time();

    if ($refresh_cache) {
        $self->refresh_building_cache();
    } else {
        $self->load_building_cache();
    }

    do {
        $do_keepalive = 0;
        for my $pid (keys %$planets) {
            next if(time() < $self->{next_action}->{$pid});
            trace("Examining ".$planets->{$pid}) if ($self->{config}->{verbosity}->{trace});
            my $colony_config = merge($config->{colony}->{$planets->{$pid}} || {},
                                      $config->{colony}->{_default_});

            next if (not exists $colony_config->{priorities} or $colony_config->{exclude});
            $self->{current}->{planet_id} = $pid;
            $self->{current}->{config} = $colony_config;
            $self->govern();
        }
        my $next_action_in = min(values %{$self->{next_action}}) - time;
        if (defined $next_action_in && $next_action_in < $config->{keepalive}) {
            trace("Expecting to govern again in $next_action_in seconds, sleeping");
            sleep($next_action_in); 
            $do_keepalive = 1;
        }
    } while ($do_keepalive); 

    $self->write_building_cache();
}

sub govern {
    my $self = shift;
    my ($pid, $cfg) = @{$self->{current}}{qw(planet_id config)};
    my $client = $self->{client};

    my $status = $client->body( id => $pid )->get_status()->{body};

    message("Governing ".$status->{name}) if ($self->{config}->{verbosity}->{message});
    Games::Lacuna::Client::PrettyPrint::show_status($status) if ($self->{config}->{verbosity}->{summary});

    if((not defined $self->{building_cache}->{body}->{$pid}) or $status->{needs_surface_refresh}) {
        my $details = $self->{client}->body( id => $pid )->get_buildings()->{buildings};
        $self->{building_cache}->{body}->{$pid} = $details; 
        for my $bid (@{$self->{building_cache}->{body}->{$pid}}) {
            $self->{building_cache}->{body}->{$pid}->{$bid}->{pretty_type} = type_from_url( $self->{building_cache}->{body}->{$pid}->{$bid}->{url} );
        }
    }

    $status->{happiness_capacity} = $cfg->{resource_profile}->{happiness}->{storage_target} || 1;
   
    for my $res (qw(food ore water energy happiness waste)) {
        my ( $amount, $capacity, $rate ) = @{$status}{ 
            $res eq 'happiness' ? 'happiness' : "$res\_stored", 
            "$res\_capacity", 
            "$res\_hour"
        };
        my $remaining            = $capacity - $amount;
        $status->{full}->{$res}  = $remaining / $rate;
        $status->{empty}->{$res} = $amount / ( -1 * $rate );
    }

    $self->{current}->{status} = $status;

    # Check the size of the build queue
    my ($dev_ministry) = $self->find_buildings('Development');
    if ($dev_ministry) {
        my $dev_min_details = $dev_ministry->view;
        my $current_queue = scalar @{$dev_min_details->{build_queue}};
        my $max_queue = $dev_min_details->{building}->{level} + 1;
        $self->{current}->{build_queue} = $dev_min_details->{build_queue};
        $self->{current}->{build_queue_remaining} = $max_queue - $current_queue;
        if ($current_queue == $max_queue) {
            warning("Build queue is full on ".$self->{current}->{status}->{name});
        } 
    } else {
        delete $self->{current}->{build_queue};
        delete $self->{current}->{build_queue_remaining};
    }

    for my $priority (@{$cfg->{priorities}}) {
        trace("Priority: $priority") if ($self->{config}->{verbosity}->{trace});
        $self->$priority();
    }

    if ($dev_ministry) {
        $self->{next_action}->{$pid} = max(map { $_->{seconds_remaining} } @{$dev_ministry->view->{build_queue}}) + time();
    }
}

sub repairs {
    # Not yet implemented.
}

sub production_crisis {
    my $self = shift;
    $self->resource_crisis('production');
}

sub storage_crisis {
    my $self = shift;
    $self->resource_crisis('storage');
}

sub resource_crisis {
    my ($self, $type) = @_;
    my $client = $self->{client};
    my ($status, $cfg) = @{$self->{current}}{qw(status config)};

    # Stop without processing if the build queue is full.
    if(defined $self->{current}->{build_queue_remaining} &&
        $self->{current}->{build_queue_remaining} == 0) {
        return;
    }

    my $key = $type eq 'production' ? 'empty' : 'full';

    for my $res (sort { $status->{$key}->{$a} <=> $status->{$key}->{$b} } keys %{$status->{$key}}) {
        my $time_left = $status->{$key}->{$res};
        if ( $time_left < $cfg->{crisis_threshhold_hours} && $time_left >= 0) {
            warning(sprintf("%s crisis detected for %s: Only %.1f hours remain until $key, less than %.1f hour threshhold.",
                ucfirst($type), uc($res), $time_left, $cfg->{crisis_threshhold_hours})) if $self->{config}->{verbosity}->{warning};

            # Attempt to increase production/storage
            my $upgrade_succeeded = $self->attempt_upgrade_for($res, $type, 1 ); # 1 for override, this is a crisis.

            if ($upgrade_succeeded) {
                my $bldg_data = $self->{building_cache}->{body}->{$status->{id}}->{$upgrade_succeeded};
                action(sprintf("Upgraded %s, %s (Level %s)",$upgrade_succeeded,$bldg_data->{pretty_type},$bldg_data->{level}));
            } else {
                warning("Could not find any suitable buildings to upgrade");
            }
            # If we could not increase production, attempt to reduce consumption (!!)
            if ($type eq 'production' and not $upgrade_succeeded and $cfg->{allow_downgrades}) {
                # Not yet implemented.
            }
        }
    }

}

sub construction {
    # Not yet implemented.
}

sub resource_upgrades {
    my ($self, $type) =  @_;
    my ($status, $cfg) = @{$self->{current}}{qw(status config)};
    my @reslist = qw(food ore water energy waste happiness);

    # Stop without processing if the build queue is full.
    if((defined $self->{current}->{build_queue_remaining}) &&
        ($self->{current}->{build_queue_remaining} <= $cfg->{reserve_build_queue})) {
        warning(sprintf("Aborting, %s slots in build queue <= %s reserve slots specified",
            $self->{current}->{build_queue_remaining},
            $cfg->{reserve_build_queue}));
        return;
    }

    my $profile = normalized_profile($cfg->{profile},@reslist);
    my $hourly_total = sum(map { abs($_) } @{$status}{ map { "$_\_hour" } @reslist});
    my $max_discrepancy;
    my $selected;

    for my $res (@reslist) {
        my $prop = $status->{"$res\_hour"} / $hourly_total;
        my $discrepancy = $profile->{$res} - $prop;
        if ($discrepancy > $max_discrepancy) {
            $max_discrepancy = $discrepancy;
            $selected = $res;
        }
    }

    message(sprintf("Discrepancy of %2d%% detected for %s production, selecting for upgrade.",$max_discrepancy*100,$selected));
    my $upgrade_succeeded = $self->attempt_upgrade_for($selected, 'production' ); # 1 for override, this is a crisis.

    if ($upgrade_succeeded) {
        my $bldg_data = $self->{building_cache}->{body}->{$status->{id}}->{$upgrade_succeeded};
        action(sprintf("Upgraded %s, %s (Level %s)",$upgrade_succeeded,$bldg_data->{pretty_type},$bldg_data->{level}));
    } else {
        warning("Could not find any suitable buildings to upgrade");
    }
}

sub normalized_profile {
    my $prof = shift;
    my $nprod = {};
    my @reslist = @_;
    my $sum = 0;
    for my $res (@reslist) {
        $sum += $nprod->{$res} = defined $prof->{$res}->{production} ? $prof->{$res}->{production} : $prof->{_default_}->{production};
    }
    if ($sum == 0) {
        return { map { $_ => 0} @reslist };
    }
    return { map { $_ => (abs($nprod->{$_}/$sum)) } @reslist };
}

sub other_upgrades {
    # Not yet implemented.
}

sub recycling {
    my ($self, $type) =  @_;
    my ($pid, $status, $cfg) = @{$self->{current}}{qw(planet_id status config)};
    my @reslist = qw(food ore water energy waste happiness);

    my $concurrency = $cfg->{profile}->{waste}->{concurrency} || 1;

    my @recycling = $self->find_buildings('WasteRecycling');
    if (not scalar @recycling) {
        warning($status->{name} . " has no recycling centers");
        return;
    }

    if ($status->{waste_stored} < $cfg->{profile}->{waste}->{recycle_above}) {
        trace("Insufficient waste to trigger recycling.");
        return;
    }

    my @available = grep { not exists $self->building_details($pid,$_->{building_id})->{work} } @recycling;
    my $jobs_running = (scalar @recycling - scalar @available);
    trace("$jobs_running recycling jobs running on ".$status->{name});

    if ($jobs_running >= $concurrency) {
        warning("Maximum (or more) concurrent recycling jobs ($concurrency) are running, aborting.");
        return;
    }

    my ($center) = @available;
    # Resource selection based on criteria.  Default is 'split'.
    my $to_recycle = $status->{waste_stored} - $cfg->{profile}->{waste}->{recycle_reserve};
    if ($to_recycle <= 0) {
        warning("Confusing directives:  Can't recycle if recycle_reserve > recycle_above");
        return;
    }

    my $criteria = $cfg->{profile}->{waste}->{recycle_selection} || 'split';
    my @rr = qw(water ore energy);
    my %recycle_res;
    my $res = undef;
    if ($criteria eq 'split') { # Split evenly
        @recycle_res{@rr}= (int($to_recycle/3)) x 3;
    } 
    elsif (any {$criteria eq $_} @rr) { # Named resource only
        $res = $criteria;
    }
    elsif ($criteria eq 'full') { # Whichever will fill up last
        ($res) = sort { $status->{full}->{$b} <=> $status->{full}->{$a} } @rr;
    }
    elsif ($criteria eq 'empty') { # Whichever will empty first
        ($res) = sort { $status->{empty}->{$a} <=> $status->{empty}->{$b} } @rr;
    }
    elsif ($criteria eq 'storage') { # Whichever we have least of
        ($res) = sort { $status->{"$a\_stored"} <=> $status->{"$b\_stored"} } @rr;
    }
    elsif ($criteria eq 'production') { # Whichever we product least of
        ($res) = sort { $status->{"$a\_hour"} <=> $status->{"$b\_hour"} } @rr;
    } else {
        warning("Unknown recycling_selection: $criteria");
        return;
    }
    if (defined $res) {
        $recycle_res{$res} = $to_recycle;
    }
    eval {
        $center->recycle(@recycle_res{@rr});
    };
    if ($@) {
        warning("Problem recycling: $@");
    } else {
        action(sprintf("Recycling Initiated: %d water, %d ore, %d energy",@recycle_res{@rr}));
    }
}

sub pushes {
    # Not yet implemented.
}

sub building_details {
    my ($self, $pid, $bid) = @_;

    if ($self->{building_cache}->{body}->{$pid}->{$bid}->{level} ne $self->{building_cache}->{building}->{$bid}->{level} or
        not defined $self->{building_cache}->{building}->{$bid}->{pretty_type}) {
        $self->refresh_building_details($self->{building_cache}->{body}->{$pid},$bid);
    }
    return merge($self->{building_cache}->{building}->{$bid},$self->{building_cache}->{body}->{$pid}->{$bid});
}

sub load_building_cache {
    my ($self) = shift;
    my $cache_file = $self->{config}->{cache_dir} . "/buildings.json";
    my $data;
    if (-e $cache_file) {
        local $/;
        eval {
            open( my $fh, '<', $cache_file );
            my $json_text   = <$fh>;
            $data = from_json( $json_text );
            close $fh;
        };
    }
    if (not defined $data) {
        trace("No cache file found, building cache") if ($self->{config}->{verbosity}->{trace});
        $self->refresh_building_cache();
    } elsif (time - $data->{cache_time} > $self->{config}->{cache_duration}) {
        trace("Cache time is too old, refreshing cache") if ($self->{config}->{verbosity}->{trace});
        $self->refresh_building_cache();
    } else {
        trace("Loading building cache") if ($self->{config}->{verbosity}->{trace});
        $self->{building_cache} = $data;
    }
}

sub refresh_building_cache {
    my ($self) = shift;

    for my $pid (keys %{$self->{status}->{empire}->{planets}}) {
        my $details = $self->{client}->body( id => $pid )->get_buildings()->{buildings};
        $self->{building_cache}->{body}->{$pid} = $details;
        $self->refresh_building_details($details,$_) for ( keys %$details );
    }
    $self->write_building_cache();
}

sub refresh_building_details {
    my ($self, $details, $bldg_id) = @_;
    my $client = $self->{client};
    
    if (not exists $details->{$bldg_id}->{pretty_type}) {
        $details->{$bldg_id}->{pretty_type} = type_from_url( $details->{$bldg_id}->{url} );
    }

    if ( not defined $details->{$bldg_id}->{pretty_type} ) {
        warning("Building $bldg_id has unknown type (".$details->{$bldg_id}->{url}.").\n");
        return;
    }

    $self->{building_cache}->{building}->{$bldg_id} = $client->building( id => $bldg_id, type => $details->{$bldg_id}->{pretty_type} )->view()->{building};
    $self->{building_cache}->{building}->{$bldg_id}->{pretty_type} = $details->{$bldg_id}->{pretty_type};
}

sub write_building_cache {
    my ($self) = shift;
    
    my $cache_file = $self->{config}->{cache_dir} . "/buildings.json";
    
    $self->{building_cache}->{cache_time} = time;

    open( my $fh, '>', $cache_file); 
    print $fh to_json($self->{building_cache});
    close $fh;
}

sub attempt_upgrade_for {
    my ($self,$resource,$type,$override) = @_;
    my ($status, $pid, $cfg) = @{$self->{current}}{qw(status planet_id config)};

    my @all_options = $self->resource_buildings($resource,$type);

    # Abort if an upgrade is in progress.
    for my $opt (@all_options) {
        if (any {$opt->{building_id} == $_->{building_id}} @{$self->{current}->{build_queue}}) {
            trace(sprintf("Upgrade already in progress for %s, aborting.",$opt->{building_id}));
            return;
        }
    }

    my @upgrade_options;

    my @options = part {
        my $bid = $_->{building_id};
        (not any { ($status->{"$_\_stored"} - 
        $self->building_details($pid,$bid)->{upgrade}->{cost}->{$_}) <
            (($cfg->{profile}->{$_}->{build_above} > 0) ?
                $cfg->{profile}->{$_}->{build_above} :
                $cfg->{profile}->{_default_}->{build_above})
        } qw(food ore water energy))+0;
    } @all_options;

    @options = map { ref $_ ? $_ : [] } @options[0,1];

    if ($override) { # Include both sets of options, non-override first
      @upgrade_options = (@{$options[1]},@{$options[0]});
    } else {
      @upgrade_options = @{$options[1]};
    }

    my $upgrade_succeeded = 0;
    for my $upgrade (@upgrade_options) {
        eval { 
            my $details = $self->building_details($pid,$upgrade->{building_id});
            trace(sprintf("Attempting to upgrade %s, %s (Level %s)",$details->{id},$details->{pretty_type},$details->{level}));
            $upgrade->upgrade(); 
        };
        if (not $@) {
            $upgrade_succeeded = $upgrade->{building_id};
        } else {
            trace("Upgrade failed: $@");
        }
        last if $upgrade_succeeded;
    }
    return $upgrade_succeeded;
}

sub resource_buildings {
    my ($self,$res,$type) = @_;
    my ($pid, $status, $cfg) = @{$self->{current}}{qw(planet_id status config)};

    my @pertinent_buildings;
    for my $bid (keys %{$self->{building_cache}->{body}->{$pid}}) {
        my $pertinent = 0;
        my $details = $self->building_details($pid,$bid);
        my $pretty_type = $details->{pretty_type};
        if ($type eq 'storage' && $details->{"$res\_capacity"} > 0) {
            $pertinent = ($pretty_type eq 'PlanetaryCommand') ? $cfg->{pcc_is_storage} : 1;
        } elsif ($type eq 'production' && $details->{"$res\_hour"} > 0) {
            $pertinent = 1;
        } elsif ($type eq 'consumption' && $details->{"$res\_hour"} < 0) {
            $pertinent = 1;
        }
        push @pertinent_buildings, $self->{client}->building( 
                id => $bid, 
                type => $pretty_type,
            ) if $pertinent;
    }
    return sort { $self->pertinence_sort($res,$cfg->{upgrade_selection},$a,$b) } @pertinent_buildings;
}

sub find_buildings {
    my ($self, $type) = @_;
    my $pid  = $self->{current}->{planet_id};
    my @retlist;

    for my $bid (keys %{$self->{building_cache}->{body}->{$pid}}) {
        my $pretty_type = $self->{building_cache}->{body}->{$pid}->{$bid}->{pretty_type};
        push @retlist, $self->{client}->building( id => $bid, type => $pretty_type ) if $pretty_type eq $type;
    }
    return @retlist;
}

sub pertinence_sort {
    my ($self,$res,$preference,$type,$left,$right) = @_;
    $preference = 'most_effective' if not defined ($preference);
    my $cache = $self->{building_cache}->{building};

    my $sort_types = {
        'most_effective' => {
            'storage'     => sub { return $cache->{ $right->{id} }->{"$res\_capacity"} <=> $cache->{ $left->{id} }->{"$res\_capacity"} },
            'production'  => sub { return $cache->{ $right->{id} }->{"$res\_hour"} <=> $cache->{ $left->{id} }->{"$res\_hour"} },
            'consumption' => sub { return $cache->{ $left->{id} }->{"$res\_hour"} <=> $cache->{ $right->{id} }->{"$res\_hour"} },
        },
        'least_effective' => {
            'storage'     => sub { return $cache->{ $left->{id} }->{"$res\_capacity"} <=> $cache->{ $right->{id} }->{"$res\_capacity"} },
            'production'  => sub { return $cache->{ $left->{id} }->{"$res\_hour"} <=> $cache->{ $right->{id} }->{"$res\_hour"} },
            'consumption' => sub { return $cache->{ $left->{id} }->{"$res\_hour"} <=> $cache->{ $right->{id} }->{"$res\_hour"} },
        },
        'most_expensive'  => sub { return sum_keys( $cache->{ $right->{id} }->{upgrade}->{cost} ) <=> sum_keys( $cache->{ $left->{id} }->{upgrade}->{cost} ) },
        'least_expensive' => sub { return sum_keys( $cache->{ $left->{id} }->{upgrade}->{cost} ) <=> sum_keys( $cache->{ $right->{id} }->{upgrade}->{cost} ) },
        'highest_level'   => sub { return $cache->{ $right->{id} }->{level} <=> $cache->{ $left->{id} }->{level} },
        'lowest_level'    => sub { return $cache->{ $left->{id} }->{level} <=> $cache->{ $right->{id} }->{level} },
        'slowest'         => sub { return $cache->{ $right->{id} }->{upgrade}->{cost}->{time} <=> $cache->{ $left->{id} }->{upgrade}->{cost}->{time} },
        'fastest'         => sub { return $cache->{ $left->{id} }->{upgrade}->{cost}->{time} <=> $cache->{ $right->{id} }->{upgrade}->{cost}->{time} },
    };
    return (ref $sort_types->{$preference} eq 'HASH') ? $sort_types->{$preference}->{$type}->() : $sort_types->{$preference}->();
}

sub upgrade_cost {
    my $hash = shift;
    return sum(@{$hash}{qw(food ore water energy waste)});
}

sub type_from_url {
    my $url   = shift;
    my @types = @Games::Lacuna::Client::Buildings::Simple::BuildingTypes;

    push @types,
        qw(Archaeology Development Embassy Intelligence Mining Network19 Observatory Park PlanetaryCommand Security Shipyard Simple SpacePort Trade Transporter WasteRecycling);
    $url = substr( $url, 1 );
    my ($ret_type) = grep { lc($url) eq lc($_) } @types;
    return $ret_type;
}

1;

__END__

=head1 NAME

Games::Lacuna::Client::Governor - A rudimentary configurable module for automation of colony maintenance

=head1 SYNOPSIS

    my $client   = Games::Lacuna::Client->new( cfg_file => $client_config );
    my $governor = Games::Lacuna::Client::Governor->new( $client, $governor_config );
    $governor->run();

=head1 DESCRIPTION

This module implements a rudimentary configurable automaton for maintaining your colonies.  
Currently, this means automation of upgrade and recycling tasks, but more is planned.
The intent is that the automation should be highly configurable, which of course has a cost
of a complex configuration file.

This script makes an effort to do its own crude caching of building data in order to minimize
the number of RPC calls per invocation.  In order to build its cache on first run, this script
will call ->view() on every building in your empire.  This is expensive.  However, after the 
first run, you can expect the script to run between 1-5 calls per colony.  In my tests the
script currently makes about 10-20 calls per invocation for an empire with 4 colonies.  
Running on an hourly cron job, this is acceptable for me.

The building data for any particular building does get refreshed from the server if the
script thinks it looks fishy, for example, if it doesn't have any data for it, or if
the building's level has changed from what is in the cache.

This module has absolutely no tests associated with it.  Use at your own risk.  I'm only
trying to be helpful.  Be kind, please rewind.  Etc. Etc.


=head1 DEPENDENCIES

I depend on Hash::Merge and List::MoreUtils to make the magic happen.  Please provide them.
I also depend on Games::Lacuna::Client (of course), and Games::Lacuna::Client::PrettyPrint,
which was published to this distribution at the same time as me.

=head1 Methods

=head2 new

Takes exactly 2 arguments, the client object built by Games::Lacuna::Client->new, and a
path to a YAML configuration file, described in the L<CONFIGURATION FILE> section below.

=head2 run

Runs the governor script according to configuration.  Takes exactly one argument, which is
treated as boolean.  If the argument is true, this will force the cache to refresh for all
buildings.  This is expensive in terms of API calls.  I don't actually use this, but it is
provided for completeness as the caching methods employed are admittedly crude.

=head1 CONFIGURATION FILE

It's a multi-level data structure.  See F<examples/governor.yml>.

=head2 cache_dir

This is a directory which must be writeable to you.  I will write my
building cache data here.

=head2 cache_duration

This is the maximum permitted age of the cache file, in seconds, before
a refresh is required.  Note the age of the cache file is updated with
each run, so this value may be set high enough that a refresh is never
forced.

=head2 keepalive

This is the window of time, in seconds, to try to keep the governor alive
if more actions are possible.  Basically, if any governed colony's build
queue will be empty before the keepalive window expires, the script will
not terminate, but will instead sleep and wait for that build queue to empty
before once again governing that colony.  Setting this to 0 will
effective disable this behavior.

=head2 verbosity

Not all of the 'verbosity' keys are currently implemented.  If any are
true, messages of that type are output to standard output.

=head3 action

Messages notifying you that some action has taken place.

=head3 construction

Outputs a construction report for each colony (not yet implemented)

=head3 message

Messages which are informational in nature.  One level above trace.

=head3 production

Outputs a production report for each colony (not yet implemented)

=head3 pushes

Outputs a colony resource push analysis (not yet implemented)

=head3 storage

Outputs a storage report for each colony (not yet implemented)

=head3 summary

Outputs a resource summary for each colony

=head3 trace

Outputs detailed information during various activities.

=head3 upgrades

Outputs an available upgrade report when analyzing upgrades (not yet implemented)

=head3 warning

Messages that an exceptional condition has been detected.

=head2 colony

See L<COLONY-SPECIFIC CONFIGURATION>.  Yes, a 'colony' key should literally
exist and contain further hashes.

=head1 COLONY-SPECIFIC CONFIGURATION

The next level beneath the 'colony' key should name (by name!) each colony
on which the governor should operate, and provide configuration for it.
If a _default_ key exists (underscores before and after), this will be
applied to all existent colonies unless overridden by colony-specific
settings.

=head2 allow_downgrades

(Not yet implemented).  Allow downgrading buildings if negative production 
levels are causing problems.  True or false.

=head2 crisis_threshhold_hours

A number of hours, decimals allowed.  

If the script detects that you will exceed
your storage capacity for any given resource in less than this amount of time,
a "storage crisis" condition is triggered which forces storage upgrades for your
resources.

If the script detects that your amount of this resource will drop to zero
in less than this amount of time, a "production crisis" condition is 
triggered which forces production upgrades for those resources.

=head2 exclude

If this is true for any particular colony which would otherwise be governed,
the governor will skip this colony and perform no actions.

=head2 pcc_is_storage

If true, the Planetary Command Center is considered a regular storage
building and will be upgraded along with others if storage is needed.
Otherwise, it will be ignored for purposes of storage upgrades.

=head2 priorities

This is a list of identifiers for each of the actions the governor
will perform.  They are performed in the order specified.  Currently
implemented values include:

production_crisis, storage_crisis, resource_upgrades, recycling

To be implemented are:

repairs, construction, other_upgrades, pushes

=head2 profile

See RESOURCE PROFILE CONFIGURATION below.  Is this getting complicated yet?
It's really not.  Okay, I lie.  Maybe it is.  I don't know anymore, my brain
is a little fried.

=head2 profile_production_tolerance

Not yet implemented.  Will permit deviations from the production profile
to pass without action.

=head2 profile_storage_tolerance

Not yet implemented.  Will permit deviations from the storage profile
to pass without action. 

=head2 reserve_build_queue

If defined, the governor will reserve this many spots at the end
of the build queue for human action (that's you).

=head2 upgrade_selection

This is a string identifier defining how the governor will select which
upgrade to perform when an upgrade is desired.  One of eight possible
values:

=head3 highest_level

The candidate building with the highest building level is selected.

=head3 lowest_level

Vice-versa.

=head3 most_effective

The candidate building which is most effective and producing or storing
the resource in question (i.e., does it most) is selected.

=head3 least_effective

Vice-versa.

=head3 most_expensive

The candidate building which will cost the most in terms of resources + waste produced
is selected.

=head3 least_expensive.

The opposite.

=head3 slowest

The candidate building which will take the longest amount of time to upgrade
is selected.

=head3 fastest

Other way around.

=head1 RESOURCE PROFILE CONFIGURATION

Okay, so this thing looks at your resource profile, as stored under the 'profile' key,
to decide how your resources should be managed.  If a _default_ key exists here, its
settings will apply to all resources (including waste and happiness) unless overridden
by more specific settings.  Note that storage-related configuration is ignored for
happiness.  Otherwise, the keys beneath 'profile' are the names of your resources:

food, ore, water, energy, waste, happiness

=head2 build_above

Attempt to reserve this amount of this resource after any potential builds.  Unless
this is a crisis, we don't do any upgrades that will bring the resource below this
amount in storage.

=head2 production

This is a funny one.  This is compared against the 'production' profile setting for
all other resources.  If, proportionately, we are falling short, this resource is
marked for a production upgrade.  For example, if all resources were set to production:1,
then it would try to make your production of everything per hour (including waste and
happiness) the same.  If you had all at 1 except for Ore at 3, it would try to produce
3 times more ore than everything else.  And so forth.

=head2 push_above

Not yet implemented.  Resources above this level are considered eligible for pushing
to more needy colonies.

=head2 want_push_to

Not yet implemented.  Defines at what level we start asking other colonies for help
in terms of resources pushes.

=head2 recycle_above

Only relevant for waste.  If above this level, trigger a recycling job (if possible).

=head2 recycle_reserve

Only relevant for waste.  When recycling, leave this amount of waste in storage. 
I.e., don't recycle it all.

=head2 recycle_selection

Only relevant for waste.  Sets a preference for what we want to recycle waste into.
Can be one of:

=head3 water, ore, or energy

Always recycle the full amount into this resource

=head3 split

Always split the amount evenly between the three types

=head3 full

Pick whichever resource will take the most time before it fills storage

=head3 empty

Pick whichever resource will take the least time before emptying

=head3 storage

Pick whichever we have the least in storage

=head3 production

Pick whichever we produce least of


=head1 SEE ALSO

Games::Lacuna::Client, by Steffen Mueller on which this module is dependent.

Of course also, the Lacuna Expanse API docs themselves at L<http://us1.lacunaexpanse.com/api>. 

The Games::Lacuna::Client distribution includes two files pertinent to this script. Well, three.  We need 
Games::Lacuna::Client::PrettyPrint for output.

Also, in F<examples>, you've got the example config file in governor.yml, and the example script in governor.pl.

=head1 AUTHOR

Adam Bellaire, E<lt>bellaire@ufl.eduE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2010 by Steffen Mueller

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.10.0 or,
at your option, any later version of Perl 5 you may have available.

=cut

