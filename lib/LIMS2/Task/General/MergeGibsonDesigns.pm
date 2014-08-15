package LIMS2::Task::General::MergeGibsonDesigns;

=head1 NAME

LIMS2::Task::General::MergeGibsonDesigns

=head1 DESCRIPTION

Merges the five arm oligos from one gibson design with the three arm oligos
from another gibson design into a brand new gibson-deletion design.

Input csv requires the following columns:
new_design_id
five_arm_design
three_arm_design
gene_id
marker_symbol

Used for recovery of gibson designs where either the 5' or 3' arm has failed.

=cut

use Moose;
use Try::Tiny;
use Text::CSV;
use MooseX::Types::Path::Class;
use feature qw( say );
use namespace::autoclean;

extends 'LIMS2::Task';

override abstract => sub {
    "Merge 5' arm and 3' arm oligos from 2 gibson designs into new gibson-deletion design";
};

has merge_design_file => (
    is            => 'ro',
    isa           => 'Path::Class::File',
    traits        => [ 'Getopt' ],
    documentation => 'CSV file with design data, required column: '
        . 'new_design_id, five_arm_design, three_arm_design, marker_symbol, gene_id',
    coerce        => 1,
    cmd_flag      => 'merge-design-file',
    required      => 1,
);

has recovery_design_comment_category_id => (
    is         => 'ro',
    isa        => 'Int',
    lazy_build => 1,
);

sub _build_recovery_design_comment_category_id {
    my $self = shift;

    my $recovery_cat = $self->model->schema->resultset('DesignCommentCategory')->find(
        {
            name => 'Recovery design',
        }
    );

    return $recovery_cat->id;
}

sub execute {
    my ( $self, $opts, $args ) = @_;
    $self->log->info();

    my $designs_data = $self->build_merge_design_data;

    $self->model->txn_do(
        sub {
            say "gene_id,marker_symbol,five_arm_design,three_arm_design,merged_design";

            for my $design_data ( @{ $designs_data } ) {
                Log::Log4perl::NDC->remove;
                Log::Log4perl::NDC->push( "5': " . $design_data->{five_arm_design} );
                Log::Log4perl::NDC->push( "3': " . $design_data->{three_arm_design} );
                try{
                    $self->merge_design( $design_data );
                }
                catch {
                    $self->log->error( "Unable to merge designs: $_" );
                };
            }

            unless ( $self->commit ) {
                $self->model->txn_rollback;
            }
        }
    );

    return;
}

=head2 build_merge_design_data

Parse the csv file with the merge design data.
Check required columns exist.

=cut
sub build_merge_design_data {
    my $self = shift;
    $self->log->info( 'Parse merge design file' );
    my @designs_data;

    my $csv = Text::CSV->new();
    my $fh = $self->merge_design_file->openr or die( 'Can not open design merge data file' );
    $csv->column_names( @{ $csv->getline( $fh ) } );

    my %columns = map { $_ => 1 } $csv->column_names;
    for my $required_name (
        ( 'five_arm_design', 'three_arm_design', 'new_design_id', 'gene_id', 'marker_symbol' ) )
    {
        unless ( exists $columns{$required_name} ) {
            die( "Missing $required_name column from csv" );
        }
    }

    while ( my $data = $csv->getline_hr( $fh ) ) {
        push @designs_data, $data;
    }

    return \@designs_data;
}

=head2 merge_design

Merge the 5F and 5R oligos from the five arm design with the 3F and 3R oligos
from the three arm design into a brand new design.

=cut
sub merge_design {
    my ( $self, $design_data ) = @_;
    $self->log->info( 'Merging designs: ' . $design_data->{five_arm_design} . ' and '
            . $design_data->{three_arm_design} );

    my $five_arm_design  = $self->model->c_retrieve_design( { id => $design_data->{five_arm_design} } );
    my $three_arm_design = $self->model->c_retrieve_design( { id => $design_data->{three_arm_design} } );
    my $new_design = $five_arm_design->id == $design_data->{new_design_id}
                     ? $five_arm_design : $three_arm_design;

    $self->check_designs( $five_arm_design, $three_arm_design, $design_data );

    my $merged_design = $new_design->copy(
        {
            design_parameters => undef,
            created_at        => \'current_timestamp',
            design_type_id    => 'gibson-deletion',
        }
    );
    $self->log->info( "New design created: $merged_design" );

    my $gene_design = $new_design->genes->first;
    my $new_gene_design = $gene_design->copy(
        {
            design_id  => $merged_design->id,
            created_at => \'current_timestamp',
        }
    );

    my $assembly = $merged_design->species->default_assembly;

    $self->copy_oligos( $merged_design, $five_arm_design, $assembly, [ '5F', '5R' ] );
    $self->copy_oligos( $merged_design, $three_arm_design, $assembly, [ '3F', '3R' ] );

    my $comment_text = 'Merge design, five arm oligos from: ' . $five_arm_design->id
                     . ' and three arm oligos from: ' . $three_arm_design->id;
    $merged_design->comments->create(
        {
            created_by                 => $new_design->created_by,
            comment_text               => $comment_text,
            design_comment_category_id => $self->recovery_design_comment_category_id,
        }
    );
    say join ',',
        (
        $design_data->{gene_id}, $design_data->{marker_symbol}, $five_arm_design->id,
        $three_arm_design->id,   $merged_design->id
        );

    return;
}

=head2 copy_oligos

Copy the specified oligos from the old design into a new one

=cut
sub copy_oligos {
    my ( $self, $merged_design, $old_design, $assembly, $oligo_types ) = @_;

    for my $type ( @{ $oligo_types } ) {
        my $oligo = $old_design->oligos->find( { design_oligo_type_id => $type } );
        my $new_oligo = $oligo->copy( { design_id => $merged_design->id } );

        my $locus = $oligo->loci( { assembly_id => $assembly->assembly_id } )->first;
        my $new_locus = $locus->copy( { design_oligo_id => $new_oligo->id  } );
        $self->log->debug( "Created new $type design oligo: " . $new_oligo->id );
    }

    return;
}

=head2 check_designs

Run some basic checks to make sure we should be merging these two designs.
    - gene_ids are the same
    - species is the same
    - both gibson type designs

=cut
sub check_designs {
    my ( $self, $five_arm_design, $three_arm_design ) = @_;

    if ( $five_arm_design->species_id ne $three_arm_design->species_id ) {
        die( 'Species of two designs do not match' );
    }

    if ( $five_arm_design->genes->first->gene_id ne $three_arm_design->genes->first->gene_id ) {
        die( 'Linked gene is not the same for two designs' );
    }

    if ( $five_arm_design->design_type_id !~ /gibson/ || $three_arm_design->design_type_id !~ /gibson/ ) {
        die( 'Both designs are not gibsons, conditional or deletion' );
    }

    return;
}

__PACKAGE__->meta->make_immutable;

1;

__END__
