package LIMS2::Tasks;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Tasks::VERSION = '0.012';
}
## use critic


use strict;
use warnings FATAL => 'all';

use Moose;
use namespace::autoclean;

extends 'MooseX::App::Cmd';

sub plugin_search_path {
    return [ 'LIMS2::Task::General', 'LIMS2::Task::YAMLDataLoader' ];
}

__PACKAGE__->meta->make_immutable;

1;

__END__
