package LIMS2::Tasks;

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
