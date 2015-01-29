package RapidApp::Util::MetaKeys::Loader;

use strict;
use warnings;
use base 'DBIx::Class::Schema::Loader::DBI';
use mro 'c3';

require Module::Runtime;
require DBIx::Class::Schema::Loader::Table;
require RapidApp::Util::MetaKeys;

use RapidApp::Include qw(sugar perlutil);
use Data::Printer;

sub new {
  my ($class, %args) = @_;
  
  my $metakeys_data = exists $args{metakeys} ? delete $args{metakeys} : undef;
  
  # test - remove me
  #$metakeys_data = '/root/metakeys.txt';
  
  my $self = $class->next::method(%args);
  
  $self->MetaKeys( $metakeys_data );
  
  # Logic duplicated from DBIx::Class::Schema::Loader::DBI
  my $driver = $self->dbh->{Driver}->{Name};
  my $subclass = 'DBIx::Class::Schema::Loader::DBI::' . $driver;
  Module::Runtime::require_module($subclass);
  
  # Create a new, runtime class for this specific driver
  unless($self->isa($subclass)) {
    my $newclass = join('::',$class,'__FOR__',$driver);
    
    no strict 'refs';
    @{$newclass."::ISA"} = ($subclass);
    $newclass->load_components('+'.$class);
    bless $self, $newclass;
    
    $self->_rebless;
    Class::C3::reinitialize() if $] < 5.009005;
  }

  return $self;
}


sub MetaKeys {
  my ($self, $new) = @_;
  $self->{_MetaKeys} = RapidApp::Util::MetaKeys->load( $new ) if ($new);
  $self->{_MetaKeys} //= undef
}


sub _table_fk_info {
  my ($self, $table) = @_;
  
  my $fks = $self->next::method($table);
  
  if(my $MetaKeys = $self->MetaKeys) {
    if(my $FKs = $MetaKeys->table_fks($table->name)) {
    
      # Add extra keys defined in our metakeys, but strip duplicates
      
      my $exist = {};
      $exist
        ->{join('|',@{$_->{local_columns}})}
        ->{$_->{remote_table}->name}
        ->{join('|',@{$_->{remote_columns}})}++
      for (@$fks);
      
      push @$fks, ( 
        map  { $self->_fk_cnf_for_metakey($table,$_) }
        grep {
          ! $exist
            ->{ $_->local_column  }
            ->{ $_->remote_table  }
            ->{ $_->remote_column }
        } @$FKs
      );
        
    }
  }
    
  $fks
}


sub _fk_cnf_for_metakey {
  my ($self, $table, $MetaFK) = @_;
  
  my $schema = $MetaFK->remote_schema || $MetaFK->local_schema || $table->schema;
  
  return {
    attrs => {
      is_deferrable => 1,
      on_delete     => 'NO ACTION',
      on_update     => 'NO ACTION'
    },
    local_columns  => [ $MetaFK->local_column ],
    remote_columns => [ $MetaFK->remote_column ],
    remote_table => DBIx::Class::Schema::Loader::Table->new(
      loader => $self,
      schema => $schema,
      name   => $MetaFK->remote_table,
    )
  }
}



1;


__END__

=head1 NAME

RapidApp::Util::MetaKeys::Loader - DBIC::S::L-compatable loader_class


=head1 DESCRIPTION

...


=head1 SEE ALSO

=over

=item *

L<RapidApp::Util::MetaKeys>

=item * 

L<RapidApp>

=back

=head1 AUTHOR

Henry Van Styn <vanstyn@cpan.org>

=head1 COPYRIGHT AND LICENSE

This software is copyright (c) 2015 by IntelliTree Solutions llc.

This is free software; you can redistribute it and/or modify it under
the same terms as the Perl 5 programming language system itself.

=cut
