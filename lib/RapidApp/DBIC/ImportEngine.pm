package RapidApp::DBIC::ImportEngine;
use Moose;

use Params::Validate ':all';
use IO::Handle;
use Try::Tiny;
use RapidApp::Debug 'DEBUG';
use RapidApp::JSON::MixedEncoder 'decode_json', 'encode_json';

has 'schema' => ( is => 'ro', isa => 'DBIx::Class::Schema', required => 1 );

has 'on_progress' => ( is => 'rw', isa => 'Maybe[CodeRef]' );
has 'progress_period' => ( is => 'rw', isa => 'Int', default => -1, trigger => \&_on_progress_period_change );
has 'next_progress' => ( is => 'rw', isa => 'Int', default => -1 );

has 'records_read' => ( is => 'rw', isa => 'Int', default => 0 );
has 'records_imported' => ( is => 'rw', isa => 'Int', default => 0 );

with 'RapidApp::DBIC::SchemaAnalysis';

# map of {ColKey}{read_id} => $saved_id
has 'auto_id_map' => ( is => 'ro', isa => 'HashRef[HashRef[Str]]', default => sub {{}} );

# map of {colKey}{missing_id} => [ [ $srcN, $rec, \@deps, $errMsg ], ... ]
has 'records_missing_keys' => ( is => 'ro', isa => 'HashRef[HashRef[ArrayRef]]', default => sub {{}} );
sub records_missing_keys_count {
	my $self= shift;
	my $cnt= 0;
	map { map { $cnt+= scalar(@$_) } values %$_ } values %{$self->records_missing_keys};
	return $cnt;
}

# array of [ [ $srcN, $rec, \@deps, $errMsg ], ... ]
has 'records_failed_insert' => ( is => 'rw', isa => 'ArrayRef[ArrayRef]', default => sub {[]} );

# map of {srcN}{primary_key} => 1
#has 'processed' => ( is => 'ro', isa => 'HashRef[HashRef]', default => sub {{}} );

sub translate_key {
	my ($self, $colkey, $val)= @_;
	return ($self->auto_id_map->{$colkey} || {})->{$val};
}

sub set_translation {
	my ($self, $colkey, $oldVal, $newVal)= @_;
	($self->auto_id_map->{$colkey} ||= {})->{$oldVal}= $newVal;
}

sub _on_progress_period_change {
	my $self= shift;
	$self->next_progress($self->progress_period) if ($self->progress_period > 0);
}

sub _send_feedback_event {
	my $self= shift;
	my $code= $self->on_progress();
	$code->() if $code;
	$self->next_progress($self->progress_period);
}

sub import_records {
	my ($self, $src)= @_;
	my ($data, $cnt, $worklist);
	$self->schema->txn_do( sub {
		my $acn;
		while (($data= $self->read_record($src))) {
			$self->import_record($data);
		}
		
		# keep trying to insert them until either no records get inserted, or until they all succeed
		if (scalar @{$self->records_failed_insert}) {
			do {
				$worklist= $self->records_failed_insert;
				$self->records_failed_insert([]);
				
				$self->perform_insert(@$_) for (@$worklist);
			} while (scalar( @{$self->records_failed_insert} ) < scalar(@$worklist));
			
			if (!$ENV{IGNORE_INVALID_RECORDS}) {
				if ($cnt= scalar @{$self->records_failed_insert}) {
					$self->report_insert_errors;
					die "$cnt records could not be added due to errors\nSee /tmp/rapidapp_import_errors.txt for details\n";
				}
			}
		}
		
		if (!$ENV{IGNORE_INVALID_RECORDS}) {
			if ($cnt= $self->records_missing_keys_count) {
				$self->report_missing_keys;
				die "$cnt records could not be added due to missing dependencies\nSee /tmp/rapidapp_import_errors.txt for details\n";
			}
		}
	});
}

sub report_missing_keys {
	my $self= shift;
	
	my $debug_fd= IO::File->new;
	$debug_fd->open('/tmp/rapidapp_import_errors.txt', 'w') or die $!;
	for my $colKey (keys %{$self->records_missing_keys}) {
		while (my ($colVal, $recs)= each %{$self->records_missing_keys->{$colKey}}) {
			$debug_fd->print("Required $colKey = '$colVal' :\n");
			$debug_fd->print("\t".encode_json($_)."\n") for (@$recs);
		}
	}
	$debug_fd->close();
}

sub report_insert_errors {
	my $self= shift;
	
	my $debug_fd= IO::File->new;
	$debug_fd->open('/tmp/rapidapp_import_errors.txt', 'w') or die $!;
	$debug_fd->print("Insertion Errors:\n");
	for my $attempt (@{$self->{records_failed_insert}}) {
		my ($srcN, $rec, $deps, $remappedRec, $errMsg)= @$attempt;
		$debug_fd->print("insert $srcN\n\tRecord   : ".encode_json($rec)."\n\tRemapped : ".encode_json($remappedRec)."\n\tError    : $errMsg\n");
	}
	$debug_fd->close();
}

sub read_record {
	my ($self, $src)= @_;
	my $line= $src->getline;
	defined($line) or return undef;
	chomp $line;
	$self->{records_read}++;
	$self->_send_feedback_event if (!--$self->{next_progress});
	return decode_json($line);
}

sub import_record {
	my $self= shift;
	my %p= validate(@_, { source => {type=>SCALAR}, data => {type=>HASHREF} });
	my $srcN= $p{source};
	my $rec= $p{data};
	defined $self->valid_sources->{$srcN} or die "Cannot import records into source $srcN";
	my $rs= $self->schema->resultset($srcN);
	my $resultClass= $rs->result_class;
	my $code;
	
	# first, handle potential import munging
	if ($code= $resultClass->can('import_create_munge')) {
		$rec= $resultClass->$code($rec);
	}
	
	# then calculate dependencies on other rows
	my $deps= ($code= $resultClass->can('calculate_record_dependencies'))?
		$resultClass->$code($rec) : $self->calculate_dependencies($srcN, $rec);
	
	my $remapped= $self->process_dependencies($srcN, $rec, $deps);
	$self->perform_insert($srcN, $rec, $deps, $remapped) if $remapped;
}

sub get_primary_key_string {
	my ($self, $rsrc, $rec)= @_;
	my @pkvals;
	for my $colN ($rsrc->primary_columns) {
		defined $rec->{$colN} or return '';  # primary key wasn't given.  Hopefully it gets autogenerated during insert.
		push @pkvals, $rec->{$colN};
	}
	return stringify_pk(@pkvals);
}

sub stringify_pk {
	join '', map { length($_).'|'.$_ } @_;
}

sub perform_insert {
	my $self= shift;
	my ($srcN, $rec, $deps, $remappedRec)= @_;
	
	DEBUG('import', 'perform_insert', $srcN, $rec);
	
	my $rs= $self->schema->resultset($srcN);
	my $resultClass= $rs->result_class;
	my ($code, $row);
	
	# perform the insert, possibly calling the Result class to do the work
	my $err;
	try {
		if ($code= $resultClass->can('import_create')) {
			$row= $resultClass->$code($rs, $remappedRec, $rec);
		} else {
			die if exists $remappedRec->{id};
			$row= $rs->create($remappedRec);
		}
		$self->{records_imported}++;
		$self->_send_feedback_event if (!--$self->{next_progress});
	}
	catch {
		$err= $_;
		$err= "$err" if (ref $err);
	};
	if ($err) {
		# we'll try it again later
		DEBUG('import', "\t[failed, deferred...]");
		push @{$self->records_failed_insert}, [ @_, $err ];
		$self->_send_feedback_event if (!--$self->{next_progress});
		return;
	}
	
	# record any auto-id values that got generated
	my @autoCols= @{$self->auto_cols_per_source->{$srcN} || []};
	my @pending;
	for my $colN (@autoCols) {
		my $origVal= $rec->{$colN};
		next unless defined $origVal;
		
		my $newVal= $row->get_column($colN);
		my $colKey= $srcN.'.'.$colN;
		($self->auto_id_map->{$colKey} ||= {})->{ $origVal }= $newVal;
		my $pendingThisCol= $self->records_missing_keys->{$colKey} || {};
		my $pendingThisKey= delete $pendingThisCol->{$origVal};
		if ($pendingThisKey) {
			DEBUG('import', "\t[resolved dep: $srcN.$colN  $origVal => $newVal");
			push @pending, @$pendingThisKey;
		}
	}
	
	# now, insert any records that depended on this one (unless they have other un-met deps, in which case they get re-queued)
	for (@pending) {
		my $remapped= $self->process_dependencies(@$_);
		$self->perform_insert(@$_, $remapped) if $remapped;
	}
}

sub calculate_dependencies {
	my ($self, $srcN, $rec)= @_;
	return $self->col_depend_per_source->{$srcN} || [];
}

sub process_dependencies {
	my $self= shift;
	my ($srcN, $rec, $deps)= @_;
	
	my $remappedRec= { %$rec };
	
	# Delete values for auto-generated keys
	# there should just be zero or one for auto_increment, but we might extend this to auto-datetimes too
	my @autoCols= @{$self->auto_cols_per_source->{$srcN} || []};
	delete $remappedRec->{$_} for (@autoCols);
	
	# swap values of any fields that need remapped
	for my $dep (@$deps) {
		my $colN= $dep->{col};
		my $oldVal= $rec->{$colN};
		# only swap the value if it was given as a scalar.  Hashes indicate fancy DBIC stuff
		if (defined $oldVal && !ref $oldVal) {
			# find the new value for the key
			my $newVal= $self->auto_id_map->{$dep->{origin_colKey}}->{$oldVal};
			
			# if we don't know it yet, we depend on this foreign column value.
			# queue this record for later insertion.
			if (!defined $newVal) {
				my $pending= (($self->records_missing_keys->{$dep->{origin_colKey}} ||= {})->{$oldVal} ||= []);
				push @$pending, [ @_ ];
				DEBUG('import', "\t[delayed due to dependency: $srcN.$colN=$oldVal => ".$dep->{origin_colKey}."=?? ]");
				$self->_send_feedback_event if (!--$self->{next_progress});
				return undef;
			}
			# swap it
			$remappedRec->{$colN}= $newVal;
		}
	}
	
	# the record will now get inserted
	return $remappedRec;
}

no Moose;
__PACKAGE__->meta->make_immutable;
1;
