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

const my $REPORT_CACHE_CONFIG => $ENV{REPORT_CACHE_CONFIG};

sub execute {
    my ( $self, $opts, $args ) = @_;

    die "No report cache config file specified"
        unless $REPORT_CACHE_CONFIG;

    $self->log->info( "Loading data from $REPORT_CACHE_CONFIG" );
    my $it = iyaml( $REPORT_CACHE_CONFIG );

    my $pm = new Parallel::ForkManager( 2 );
    $pm->run_on_start( 
        sub {
            my ($pid,$ident) = @_;
            print "Starting report caching $ident under process id $pid\n";
        }
    );

    while ( my $datum = $it->next ) {
        $pm->start( $datum->{name} ) and next; #forks child process

        # All work done here in child process

        try{
            $self->cache_report( $datum );
        }
        catch {
            $self->log->error( "Error creating " . $datum->{name} . '  ' . $_ );
        };

        $pm->finish; # Terminate child process
    }

    $pm->wait_all_children;
    $self->log->info( 'All specified reports have been cached' );

    return;
}

sub cache_report {
    my ( $self, $datum ) = @_;
    
    $self->log->debug( "Attempting to cached report: " . $datum->{name} );

    my $report_id = LIMS2::Report::cached_report(
        model      => $self->model,
        report     => $datum->{report_type},
        params     => $datum->{report_params},
    );

    my $done;
    my $num_attempts = 10;

    while ( $num_attempts-- and not $done ) {
        sleep 10;
        $done = $self->report_complete( $report_id );
    }

    die( "$datum->{name} report did not generate in time allocated: " . $report_id )
        unless $done;

    $self->log->info( 'Cached report: ' . $datum->{name} );

    return;
}

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

__PACKAGE__->meta->make_immutable;

1;

__END__
