package LIMS2::Task::General::CacheReports;

use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Report;
use LIMS2::Util::YAMLIterator;
use Const::Fast;
use Try::Tiny;
use Parallel::ForkManager;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Pre Cache reports for webapp';
};

const my $REPORT_CACHE_CONFIG => $ENV{LIMS2_REPORT_CACHE_CONFIG};
const my $MAX_PROCESSES => 2;

sub execute {
    my ( $self, $opts, $args ) = @_;

    die "No report cache config file specified"
        unless $REPORT_CACHE_CONFIG;

    $self->log->info( "Loading data from $REPORT_CACHE_CONFIG" );
    my $it = iyaml( $REPORT_CACHE_CONFIG );

    my $pm = Parallel::ForkManager->new( $MAX_PROCESSES );

    $pm->run_on_start(
        sub {
            my ($pid,$ident) = @_;
            $self->log->info("Starting report caching $ident ( process $pid )" );
        }
    );

    while ( my $datum = $it->next ) {
        $pm->start( $datum->{name} ) and next; #forks child process

        # All work done here in child process
        try{
            $self->cache_report( $datum );
        }
        catch {
            $self->log->error( "Failed to cache report $datum->{name} : " . $_ );
        };

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
    );

    sleep 1;
    my $done = $self->report_complete( $report_id );
    if ( $done ) {
        $self->log->info( 'Report already cached ' . $report_id );
        return;
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


    return;
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

__PACKAGE__->meta->make_immutable;

1;

__END__
