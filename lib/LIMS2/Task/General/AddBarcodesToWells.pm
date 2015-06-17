package LIMS2::Task::General::AddBarcodesToWells;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $LIMS2::Task::General::AddBarcodesToWells::VERSION = '0.016';
}
## use critic

use strict;
use warnings FATAL => 'all';

=head1 NAME

LIMS2::Task::General::CreateCrisprPlate

=head1 DESCRIPTION

This command adds barcodes to plates in LIMS2.
Required options:
- plate: Name of plate to add barcodes to
- user: Name of user creating the plate
- plate-data-file: File containing barcode data

The plate data file is a csv file, with 2 columns:
- well_name
- well_barcode

The file must have these column headers.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use MooseX::Types::Path::Class;
use autodie;
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    'Add barcodes to wells on a plate';
};

has plate => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'Name of crispr plate',
    required      => 1,
);

has plate_data_file => (
    is            => 'ro',
    isa           => 'Path::Class::File',
    traits        => [ 'Getopt' ],
    documentation => 'File holding design plate data, 2 column, well_name and well_barcode',
    coerce        => 1,
    cmd_flag      => 'plate-data-file',
    required      => 1,
);

has user => (
    is            => 'ro',
    isa           => 'Str',
    traits        => [ 'Getopt' ],
    documentation => 'User who is creating the plate',
    required      => 1,
);

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info( 'Creating crispr plate: ' . $self->plate );

    my $barcodes = $self->process_csv;

    $self->model->txn_do(
        sub {
            my $plate = $self->model->retrieve_plate(
                { name => $self->plate },
                { prefetch => { wells => 'well_barcode' } }
            );

            for my $well ( $plate->wells ) {
                next unless exists $barcodes->{ $well->name };
                die "Barcode already exists for " . $well->name if $well->well_barcode;

                $well->create_related( 'well_barcode', { barcode => $barcodes->{$well->name} } );

                $self->log->debug( 'Assigned ' . $barcodes->{$well->name} . ' to ' . $well->name );
            }

            unless ( $self->commit ) {
                $self->model->txn_rollback;
            }
        }
    );

    return;
}

sub process_csv {
    my $self = shift;

    $self->log->info( 'Processing CSV file' );

    my $csv = Text::CSV->new;
    my $fh = $self->plate_data_file->openr;

    $csv->column_names( @{ $csv->getline( $fh ) } );

    my %well_data;

    while ( my $data = $csv->getline_hr( $fh ) ) {
        $well_data{ $data->{well_name} } = $data->{barcode};
    }

    return \%well_data;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
