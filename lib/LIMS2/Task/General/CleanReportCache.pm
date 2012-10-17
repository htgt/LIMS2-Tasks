package LIMS2::Task::General::CleanReportCache;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::CleanReportCache::VERSION = '0.005';
}
## use critic


use strict;
use warnings FATAL => 'all';

use Moose;
use LIMS2::Report;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Delete stale entries from the report cache';
};

sub execute {
    my ( $self, $opts, $args ) = @_;

    my $verbose = $self->trace || $self->debug || $self->verbose;

    LIMS2::Report::clean_cache( $self->model, $verbose );

    return;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
