package LIMS2::Task::General::CacheReports;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CacheReports::VERSION = '0.007';
}
## use critic


#
# script setup to run under t87svc on t87-solr vm
# this is so scp file transfer to t87-catalyst can be completed without entering a password
#

use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Report;
use LIMS2::Util::YAMLIterator;
use Const::Fast;
use Try::Tiny;
use Parallel::ForkManager;
use namespace::autoclean;
use IPC::System::Simple qw( system );

extends 'LIMS2::Task';

has max_processes => (
    is       => 'ro',
    isa      => 'Int',
    default  => 2,
    traits   => [ 'Getopt' ],
    cmd_flag => 'max-processes'
);

override abstract => sub {
    'Pre Cache reports for webapp';
};

const my $LIMS2_REPORT_CACHE_CONFIG => $ENV{LIMS2_REPORT_CACHE_CONFIG};
const my $LIMS2_REPORT_DIR          => $ENV{LIMS2_REPORT_DIR};

sub execute {
    my ( $self, $opts, $args ) = @_;

    die "No LIMS2 report directory specified"
        unless $LIMS2_REPORT_DIR;

    die "No report cache config file specified"
        unless $LIMS2_REPORT_CACHE_CONFIG;

    $self->log->info( "Loading data from $LIMS2_REPORT_CACHE_CONFIG" );
    my $it = iyaml( $LIMS2_REPORT_CACHE_CONFIG );

    my $pm = Parallel::ForkManager->new( $self->max_processes );

    $pm->run_on_start(
        sub {
            my ($pid,$ident) = @_;
            $self->log->info("Starting report caching $ident ( process $pid )" );
        }
    );

    while ( my $datum = $it->next ) {
        $pm->start( $datum->{name} ) and next; #forks child process

        my $report_id;
        # All work done here in child process
        try{
            $report_id = $self->cache_report( $datum );
        }
        catch {
            $self->log->error( "Failed to cache report $datum->{name} : " . $_ );
        };

        $self->transfer_report_dir( $report_id )
            if $report_id;

        $pm->finish(); # Terminate child process
    }

    $pm->wait_all_children;
    $self->log->info( 'All specified reports have been cached' );

    return;
}

sub cache_report {
    my ( $self, $datum ) = @_;

    my $report_id = LIMS2::Report::cached_report(
        model      => $self->model,
        report     => $datum->{report_type},
        params     => $datum->{report_params},
        force      => 1,
    );

    sleep 1;
    my $done = $self->report_complete( $report_id );
    if ( $done ) {
        $self->log->info( 'Report already cached ' . $report_id );
        return $report_id;
    }

    my $num_attempts = 90;

    while ( $num_attempts-- and not $done ) {
        sleep 60;
        $done = $self->report_complete( $report_id );
    }

    # need to delete cache entry if we die here , because process will be killed
    unless ( $done ) {
        $self->model->schema->resultset('CachedReport')->find( { id => $report_id } )->delete;
        $self->log->error("Deleting cached_report entry: $report_id ");

        die( "Report did not generate in time allocated: " . $report_id );
    }


    return $report_id;
}

## no critic(ControlStructures::ProhibitCascadingIfElse)
sub report_complete {
    my ( $self, $report_id ) = @_;

    my $status = LIMS2::Report::get_report_status( $report_id );

    if ( $status eq 'NOT_FOUND' ) {
        die("Can not find folder for report $report_id");
    }
    elsif ( $status eq 'FAILED' ) {
        die("Failed to generate report $report_id");
    }
    elsif ( $status eq 'PENDING' ) {
        return;
    }
    elsif ( $status eq 'DONE' ) {
        return 1;
    }
    else {
        die("Unrecognised status for report $report_id " . $status);
    }

    return;
}
## use critic

sub transfer_report_dir {
    my ( $self, $report_id ) = @_;

    # check report_dir exists and is done
    my $status = LIMS2::Report::get_report_status( $report_id );
    unless ( $status eq 'DONE' ) {
        $self->log->error("Can't transfer report $report_id, status is $status" );
        return;
    }

    # Run in batch mode ( -B ) will only work if passwordless login is setup
    system(
        'scp',
        '-q',
        '-r',
        '-B',
        "$LIMS2_REPORT_DIR" .'/' . "$report_id",
        't87svc@t87-catalyst:' . "$LIMS2_REPORT_DIR",
    );
    $self->log->info("Transfered report folder $report_id to t87-catalyst");

    return;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
