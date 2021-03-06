use strict;
use warnings FATAL => 'all';

package MarpaX::Languages::C::AST::Callback::Events;
use MarpaX::Languages::C::AST::Util qw/:all/;
use parent qw/MarpaX::Languages::C::AST::Callback/;

# ABSTRACT: Events callback when translating a C source to an AST

use Carp qw/croak/;
use Storable qw/dclone/;
use SUPER;
use constant LHS_RESET_EVENT => '<reset>';
use constant LHS_PROCESS_EVENT => '<process>';
use constant CLOSEANYSCOPE_PRIORITY => -1000;
use constant RESETANYDATA_PRIORITY => -2000;

# VERSION

=head1 DESCRIPTION

This modules implements the Marpa events callback using the very simple framework MarpaX::Languages::C::AST::Callback. It is useful because it shows the FUNCTIONAL things that appear within the events: monitor the TYPEDEFs, introduce/obscure names in name space, apply the few grammar constraints needed at parsing time, etc.

=cut

sub new {
    my ($class, $outerSelf) = @_;

    my $self = $class->SUPER();

    if (! defined($outerSelf) || ref($outerSelf) ne 'MarpaX::Languages::C::AST') {
      croak 'outerSelf must be a reference to MarpaX::Languages::C::AST';
    }

    $self->hscratchpad('_impl', $outerSelf->{_impl});
    $self->hscratchpad('_scope', $outerSelf->{_scope});
    $self->hscratchpad('_sourcep', $outerSelf->{_sourcep});

    # #######################################################################################################################
    # From now on, the technique is always the same:
    #
    # For a rule that will be isolated for convenience (the grammar uses the action => deref if needed) like:
    # LHS ::= RHS1 RHS2 ... RHSn
    #
    # Suppose we want, at <LHS$> to inspect genome data <Gx,y,...> aggregation associated with rule <RHSn>.
    #
    # - We create a brand new callback object:
    # - We make sure LHS rule is unique, creating a proxy rule with action => deref if needed
    # - We make sure <LHS$> completion event exist
    # - We make sure <LHSRHSn$> completion events exist
    # - We make sure <^LHSRHSn> predictions events exist
    # - We create a dedicated callback that is subscribed to every unique <Gx$> and that collect its data
    #
    # - Every <^LHSRHSn> is resetting the data collections they depend upon
    # - Every <LHSRHSn$> is copying the data collections they depend upon and reset it
    # - The first LHSRHS has a special behaviour: if <LHSRHS$> is hitted while there is a pending <LHS$>,
    #   this mean that we are recursively hitting the rule. This will push one level. Levels are popped off at <LHS$>.
    #
    # - We create callbacks to <Gx$> that are firing the inner callback object.
    #
    # - For these callbacks we want to know if the scopes must be all closed before doing the processing.
    #   This is true in general except for functionDefinitionCheck1 and functionDefinitionCheck2 where we want to
    #   access the declarationList at scope 1 and the declarationSpecifiers at scope 0.
    #
    # #######################################################################################################################

    # ################################################################################################
    # A directDeclarator introduces a typedef-name only when it eventually participates in the grammar
    # rule:
    # declaration ::= declarationSpecifiers initDeclaratorList SEMICOLON
    #
    # Isolated to single rule:
    #
    # declarationCheck ::= declarationCheckdeclarationSpecifiers declarationCheckinitDeclaratorList
    #                      SEMICOLON action => deref
    # ################################################################################################
    my @callbacks = ();
    push(@callbacks,
         $self->_register_rule_callbacks({
                                          lhs => 'declarationCheck',
                                          rhs => [ [ 'declarationCheckdeclarationSpecifiers', [ 'storageClassSpecifierTypedef' ] ],
                                                   [ 'declarationCheckinitDeclaratorList',    ['directDeclaratorIdentifier'  ] ]
                                                 ],
                                          method => \&_declarationCheck,
                                          # ---------------------------
                                          # directDeclarator constraint
                                          # ---------------------------
                                          # In:
                                          # structDeclarator ::= declarator COLON constantExpression | declarator
                                          #
                                          # ordinary name space names cannot be defined. Therefore all parse symbol activity must be
                                          # suspended for structDeclarator.
                                          #
                                          # structDeclarator$ will be hitted many time (right recursive), but its container
                                          # structDeclaration will be hitted only once.
                                          # ---------------------------
                                          counters => {
                                                       'structContext' => [ 'structContextStart[]', 'structContextEnd[]' ]
                                                      },
                                          process_priority => CLOSEANYSCOPE_PRIORITY - 1,
                                         }
                                        )
        );


    # ------------------------------------------------------------------------------------------
    # directDeclarator constraint
    # ------------------------------------------------------------------------------------------
    # In:
    # functionDefinition ::= declarationSpecifiers declarator declarationList? compoundStatement
    # typedef is syntactically allowed but never valid in either declarationSpecifiers or
    # declarationList.
    #
    # Isolated to two rules:
    #
    # functionDefinitionCheck1 ::= functionDefinitionCheck1declarationSpecifiers declarator
    #                              functionDefinitionCheck1declarationList
    #                              compoundStatementReenterScope action => deref
    # functionDefinitionCheck2 ::= functionDefinitionCheck2declarationSpecifiers declarator
    #                              compoundStatementReenterScope action => deref
    #
    # Note: We want the processing to happen before the scopes are really closed.
    # ------------------------------------------------------------------------------------------
    push(@callbacks,
         $self->_register_rule_callbacks({
                                          lhs => 'functionDefinitionCheck1',
                                          rhs => [ [ 'functionDefinitionCheck1declarationSpecifiers', [ 'storageClassSpecifierTypedef' ] ],
                                                   [ 'functionDefinitionCheck1declarationList',       [ 'storageClassSpecifierTypedef' ] ]
                                                 ],
                                          method => \&_functionDefinitionCheck1,
                                          process_priority => CLOSEANYSCOPE_PRIORITY + 1,
                                         }
                                        )
        );
    push(@callbacks,
         $self->_register_rule_callbacks({
                                          lhs => 'functionDefinitionCheck2',
                                          rhs => [ [ 'functionDefinitionCheck2declarationSpecifiers', [ 'storageClassSpecifierTypedef' ] ],
                                                 ],
                                          method => \&_functionDefinitionCheck2,
                                          process_priority => CLOSEANYSCOPE_PRIORITY + 1,
                                         }
                                        )
        );

    # ------------------------------------------------------------------------------------------
    # directDeclarator constraint
    # ------------------------------------------------------------------------------------------
    # In:
    # parameterDeclaration ::= declarationSpecifiers declarator
    # typedef is syntactically allowed but never valid.
    #
    # Isolated to:
    #
    # parameterDeclarationCheck ::= declarationSpecifiers declarator
    # ------------------------------------------------------------------------------------------
    push(@callbacks,
         $self->_register_rule_callbacks({
                                          lhs => 'parameterDeclarationCheck',
                                          rhs => [ [ 'parameterDeclarationdeclarationSpecifiers', [ 'storageClassSpecifierTypedef' ] ]
                                                 ],
                                          method => \&_parameterDeclarationCheck,
                                         }
                                        )
        );
    # ################################################################################################
    # An enumerationConstantIdentifier introduces a enum-name. Full point.
    # rule:
    # enumerationConstantIdentifier ::= IDENTIFIER
    # ################################################################################################
    $self->register(MarpaX::Languages::C::AST::Callback::Method->new
		    (
		     description => 'enumerationConstantIdentifier$',
		     method =>  [ \&_enumerationConstantIdentifier ],
		     option => MarpaX::Languages::C::AST::Callback::Option->new
		     (
		      condition => [ [ 'auto' ] ],
		     )
		    )
	);

    # #############################################################################################
    # Register scope callbacks
    # #############################################################################################
    $self->hscratchpad('_scope')->parseEnterScopeCallback(\&_enterScopeCallback, $self, @callbacks);
    $self->hscratchpad('_scope')->parseExitScopeCallback(\&_exitScopeCallback, $self, @callbacks);
    #
    # and the detection of filescope declarator
    #
    $self->register(MarpaX::Languages::C::AST::Callback::Method->new
		    (
		     description => 'fileScopeDeclarator$',
		     method => [ \&_set_helper, 'fileScopeDeclarator', 1, 'reenterScope', 0 ],
                     method_void => 1,
		     option => MarpaX::Languages::C::AST::Callback::Option->new
		     (
		      condition => [
                                    [ 'auto' ],
                                    [ sub { my ($method, $callback, $eventsp, $scope) = @_;
                                            return ($scope->parseScopeLevel == 0);
                                          },
                                      $self->hscratchpad('_scope')
                                    ]
                                   ],
		      topic => {'fileScopeDeclarator' => 1,
                                'reenterScope' => 1},
		      topic_persistence => 'any',
		     )
		    )
	);
    #
    # ^externalDeclaration will always close any remaining scope and reset all data
    #
    $self->register(MarpaX::Languages::C::AST::Callback::Method->new
                    (
		     description => '^externalDeclaration',
		     method => [ \&_closeAnyScope, $self->hscratchpad('_scope') ],
		     option => MarpaX::Languages::C::AST::Callback::Option->new
		     (
		      condition => [ [ 'auto' ] ],
                      priority => CLOSEANYSCOPE_PRIORITY
		     )
		    )
	);
    $self->register(MarpaX::Languages::C::AST::Callback::Method->new
                    (
		     description => '^externalDeclaration',
		     method => [ \&_resetAnyData, @callbacks ],
		     option => MarpaX::Languages::C::AST::Callback::Option->new
		     (
		      condition => [ [ 'auto' ] ],
                      priority => RESETANYDATA_PRIORITY
		     )
		    )
	);

    return $self;
}
# ----------------------------------------------------------------------------------------
sub _closeAnyScope {
    my ($method, $callback, $eventsp, $scope) = @_;

    while ($scope->parseScopeLevel >= 1) {
      $scope->doExitScope();
    }
}
# ----------------------------------------------------------------------------------------
sub _resetAnyData {
    my ($method, $callback, $eventsp, @callbacks) = @_;

    foreach (@callbacks) {
      $_->exec(LHS_RESET_EVENT);
    }
}
# ----------------------------------------------------------------------------------------
sub _enumerationConstantIdentifier {
    my ($method, $callback, $eventsp) = @_;

    my $enum = lastCompleted($callback->hscratchpad('_impl'), 'enumerationConstantIdentifier');
    $callback->hscratchpad('_scope')->parseEnterEnum($enum);
}
# ----------------------------------------------------------------------------------------
sub _parameterDeclarationCheck {
    my ($method, $callback, $eventsp) = @_;
    #
    # Get the topics data we are interested in
    #
    my $parameterDeclarationdeclarationSpecifiers = $callback->topic_level_fired_data('parameterDeclarationdeclarationSpecifiers$');

    #
    # By definition parameterDeclarationdeclarationSpecifiers contains only typedefs
    #
    my $nbTypedef = $#{$parameterDeclarationdeclarationSpecifiers};
    if ($nbTypedef >= 0) {
	my ($line_columnp, $last_completed)  = @{$parameterDeclarationdeclarationSpecifiers->[0]};
	logCroak("[%s[%d]] %s is not valid in a parameter declaration\n%s\n", whoami(__PACKAGE__), $callback->currentTopicLevel, $last_completed, showLineAndCol(@{$line_columnp}, $callback->hscratchpad('_sourcep')));
    }
}
# ----------------------------------------------------------------------------------------
sub _functionDefinitionCheck1 {
    my ($method, $callback, $eventsp) = @_;
    #
    # Get the topics data we are interested in
    #
    my $functionDefinitionCheck1declarationSpecifiers = $callback->topic_level_fired_data('functionDefinitionCheck1declarationSpecifiers$', -1);
    my $functionDefinitionCheck1declarationList = $callback->topic_fired_data('functionDefinitionCheck1declarationList$');

    #
    # By definition functionDefinitionCheck1declarationSpecifiers contains only typedefs
    # By definition functionDefinitionCheck1declarationList contains only typedefs
    #
    my $nbTypedef1 = $#{$functionDefinitionCheck1declarationSpecifiers};
    if ($nbTypedef1 >= 0) {
	my ($line_columnp, $last_completed)  = @{$functionDefinitionCheck1declarationSpecifiers->[0]};
	logCroak("[%s[%d]] %s is not valid in a function declaration specifier\n%s\n", whoami(__PACKAGE__), $callback->currentTopicLevel, $last_completed, showLineAndCol(@{$line_columnp}, $callback->hscratchpad('_sourcep')));
    }

    my $nbTypedef2 = $#{$functionDefinitionCheck1declarationList};
    if ($nbTypedef2 >= 0) {
	my ($line_columnp, $last_completed)  = @{$functionDefinitionCheck1declarationList->[0]};
	logCroak("[%s[%d]] %s is not valid in a function declaration list\n%s\n", whoami(__PACKAGE__), $callback->currentTopicLevel, $last_completed, showLineAndCol(@{$line_columnp}, $callback->hscratchpad('_sourcep')));
    }
}
sub _functionDefinitionCheck2 {
    my ($method, $callback, $eventsp) = @_;
    #
    # Get the topics data we are interested in
    #
    my $functionDefinitionCheck2declarationSpecifiers = $callback->topic_level_fired_data('functionDefinitionCheck2declarationSpecifiers$', -1);

    #
    # By definition functionDefinitionCheck2declarationSpecifiers contains only typedefs
    #
    my $nbTypedef = $#{$functionDefinitionCheck2declarationSpecifiers};
    if ($nbTypedef >= 0) {
	my ($line_columnp, $last_completed)  = @{$functionDefinitionCheck2declarationSpecifiers->[0]};
	logCroak("[%s[%d]] %s is not valid in a function declaration specifier\n%s\n", whoami(__PACKAGE__), $callback->currentTopicLevel, $last_completed, showLineAndCol(@{$line_columnp}, $callback->hscratchpad('_sourcep')));
    }
}
# ----------------------------------------------------------------------------------------
sub _declarationCheck {
    my ($method, $callback, $eventsp) = @_;

    #
    # Check if we are in structContext context
    #
    my $structContext = $callback->topic_fired_data('structContext') || [0];
    if ($structContext->[0]) {
	return;
    }
    #
    # Get the topics data we are interested in
    #
    my $declarationCheckdeclarationSpecifiers = $callback->topic_fired_data('declarationCheckdeclarationSpecifiers$');
    my $declarationCheckinitDeclaratorList = $callback->topic_fired_data('declarationCheckinitDeclaratorList$');

    #
    # By definition declarationCheckdeclarationSpecifiers contains only typedefs
    # By definition declarationCheckinitDeclaratorList contains only directDeclaratorIdentifier
    #

    my $nbTypedef = $#{$declarationCheckdeclarationSpecifiers};
    if ($nbTypedef > 0) {
	#
	# Take the second typedef
	#
	my ($line_columnp, $last_completed)  = @{$declarationCheckdeclarationSpecifiers->[1]};
	logCroak("[%s[%d]] %s cannot appear more than once\n%s\n", whoami(__PACKAGE__), $callback->currentTopicLevel, $last_completed, showLineAndCol(@{$line_columnp}, $callback->hscratchpad('_sourcep')));
    }
    foreach (@{$declarationCheckinitDeclaratorList}) {
	my ($line_columnp, $last_completed, %counters)  = @{$_};
        if (! $counters{structContext}) {
          if ($nbTypedef >= 0) {
	    $callback->hscratchpad('_scope')->parseEnterTypedef($last_completed);
          } else {
	    $callback->hscratchpad('_scope')->parseObscureTypedef($last_completed);
          }
        }
    }
}
# ----------------------------------------------------------------------------------------
sub _enterScopeCallback {
    foreach (@_) {
	$_->pushTopicLevel();
    }
}
sub _exitScopeCallback {
    foreach (@_) {
	$_->popTopicLevel();
    }
}
# ----------------------------------------------------------------------------------------
sub _storage_helper {
    my ($method, $callback, $eventsp, $event, $countersHashp) = @_;
    #
    # Collect the counters
    #
    my %counters = ();
    foreach (keys %{$countersHashp}) {
      my $counterDatap = $callback->topic_fired_data($_) || [0];
      $counters{$_} = $counterDatap->[0] || 0;
    }
    #
    # The event name, by convention, is 'symbol$' or '^$symbol'
    #
    my $symbol = $event;
    my $rc;
    if (substr($symbol, 0, 1) eq '^') {
	substr($symbol, 0, 1, '');
	$rc = [ lineAndCol($callback->hscratchpad('_impl')), %counters ];
    } elsif (substr($symbol, -1, 1) eq '$') {
	substr($symbol, -1, 1, '');
	$rc = [ lineAndCol($callback->hscratchpad('_impl')), lastCompleted($callback->hscratchpad('_impl'), $symbol), %counters ];
    }

    return $rc;
}
# ----------------------------------------------------------------------------------------
sub _inc_helper {
    my ($method, $callback, $eventsp, $topic, $increment) = @_;

    my $old_value = $callback->topic_fired_data($topic)->[0] || 0;
    my $new_value = $old_value + $increment;

    return $new_value;
}
# ----------------------------------------------------------------------------------------
sub _set_helper {
    my ($method, $callback, $eventsp, %topic) = @_;

    foreach (keys %topic) {
      $callback->topic_fired_data($_, [ $topic{$_} ]);
    }
}
# ----------------------------------------------------------------------------------------
sub _reset_helper {
    my ($method, $callback, $eventsp, @topics) = @_;

    my @rc = ();
    return @rc;
}
# ----------------------------------------------------------------------------------------
sub _collect_helper {
    my ($method, $callback, $eventsp, @topics) = @_;

    my @rc = ();
    foreach (@topics) {
	my $topic = $_;
	push(@rc, @{$callback->topic_fired_data($topic)});
	$callback->topic_fired_data($topic, []);
    }

    return @rc;
}
# ----------------------------------------------------------------------------------------
sub _subFire {
  my ($method, $callback, $eventsp, $lhs, $subCallback, $filterEventsp, $transformEventsp) = @_;

  my @subEvents = grep {exists($filterEventsp->{$_})} @{$eventsp};
  if (@subEvents) {
    if (defined($transformEventsp)) {
      my %tmp = ();
      my @transformEvents = grep {++$tmp{$_} == 1} map {$transformEventsp->{$_} || $_} @subEvents;
      $subCallback->exec(@transformEvents);
    } else {
      $subCallback->exec(@subEvents);
    }
  }
}
# ----------------------------------------------------------------------------------------
sub _register_rule_callbacks {
  my ($self, $hashp) = @_;

  #
  # Create inner callback object
  #
  my $callback = MarpaX::Languages::C::AST::Callback->new(log_prefix => '  ' . $hashp->{lhs} . ' ');
  $callback->hscratchpad('_impl', $self->hscratchpad('_impl'));
  $callback->hscratchpad('_scope', $self->hscratchpad('_scope'));
  $callback->hscratchpad('_sourcep', $self->hscratchpad('_sourcep'));

  #
  # rshProcessEvents will be the list of processing events that we forward to the inner callback object
  #
  my %rshProcessEvents = ();
  #
  # Counters are events associated to a counter: every ^xxx increases a counter.
  # Every xxx$ is decreasing it.
  # To any genome data, we have attached a hash like {counter1 => counter1_value, counter2 => etc...}
  #
  my $countersHashp = $hashp->{counters} || {};
  foreach (keys %{$countersHashp}) {
    my $counter = $_;
    my ($eventStart, $eventEnd) = @{$countersHashp->{$counter}};
    ++$rshProcessEvents{$eventStart};
    $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
                        (
                         description => $eventStart,
                         extra_description => $counter . ' [Start] ',
                         method =>  [ \&_inc_helper, $counter, 1 ],
                         method_mode => 'replace',
                         option => MarpaX::Languages::C::AST::Callback::Option->new
                         (
                          topic => {$counter => 1},
                          topic_persistence => 'any',
                          condition => [ [ 'auto' ] ],  # == match on description
                          priority => 999,
                         )
                        )
                       );
    ++$rshProcessEvents{$eventEnd};
    $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
                        (
                         description => $eventEnd,
                         extra_description => $counter . ' [End] ',
                         method =>  [ \&_inc_helper, $counter, -1 ],
                         method_mode => 'replace',
                         option => MarpaX::Languages::C::AST::Callback::Option->new
                         (
                          topic => {$counter => 1},
                          topic_persistence => 'any',
                          condition => [ [ 'auto' ] ],  # == match on description
                          priority => 999,
                         )
                        )
                       );
  }

  #
  # Collect the unique list of <Gx$>
  #
  my %genomeEvents = ();
  foreach (@{$hashp->{rhs}}) {
    my ($rhs, $genomep) = @{$_};
    foreach (@{$genomep}) {
	my $event = $_ . '$';
	++$genomeEvents{$event};
	++$rshProcessEvents{$event};
    }
  }
  #
  # Create data Gx$ data collectors. The data will be collected in a
  # topic with the same name: Gx
  #
  foreach (keys %genomeEvents) {
	$callback->register(MarpaX::Languages::C::AST::Callback::Method->new
			    (
			     description => $_,
                             extra_description => "$_ [storage] ",
			     method =>  [ \&_storage_helper, $_, $countersHashp ],
			     option => MarpaX::Languages::C::AST::Callback::Option->new
			     (
			      topic => {$_ => 1},
			      topic_persistence => 'level',
			      condition => [ [ 'auto' ] ],  # == match on description
			      priority => 999,
			     )
			    )
	    );
  }

  my $i = 0;
  my %rhsTopicsToUpdate = ();
  my %rhsTopicsNotToUpdate = ();
  foreach (@{$hashp->{rhs}}) {
    my ($rhs, $genomep) = @{$_};
    my $rhsTopic = $rhs . '$';
    $rhsTopicsToUpdate{$rhsTopic} = 1;
    $rhsTopicsNotToUpdate{$rhsTopic} = -1;

    my %genomeTopicsToUpdate = ();
    my %genomeTopicsNotToUpdate = ();
    foreach (@{$genomep}) {
      $genomeTopicsToUpdate{$_ . '$'} = 1;
      $genomeTopicsNotToUpdate{$_ . '$'} = -1;
    }
    #
    # rhs$ event will collect into rhs$ topic all Gx$ topics (created automatically if needed)
    #
    my $event = $rhs . '$';
    ++$rshProcessEvents{$event};
    $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
			(
			 description => $event,
                         extra_description => "$event [process] ",
			 method =>  [ \&_collect_helper, keys %genomeTopicsNotToUpdate ],
			 method_mode => 'push',
			 option => MarpaX::Languages::C::AST::Callback::Option->new
			 (
			  condition => [ [ 'auto' ] ],  # == match on description
			  topic => {$rhsTopic => 1,
                                   %genomeTopicsNotToUpdate},
			  topic_persistence => 'level',
			  priority => 1,
			 )
			)
	);
    #
    ## .. and reset them
    #
    $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
			(
			 description => $event,
                         extra_description => "$event [reset] ",
			 method =>  [ \&_reset_helper, keys %genomeTopicsToUpdate ],
			 method_mode => 'replace',
			 option => MarpaX::Languages::C::AST::Callback::Option->new
			 (
			  condition => [ [ 'auto' ] ],  # == match on description
			  topic => {%genomeTopicsToUpdate},
			  topic_persistence => 'level',
			  priority => 0,
			 )
			)
	);

  }

  #
  # Final callback: this will process the event
  #
  my $lhsProcessEvent = LHS_PROCESS_EVENT;
  my %lhsProcessEvents = ($hashp->{lhs} . '$' => 1);
  my $lhsResetEvent = LHS_RESET_EVENT;
  my %lhsResetEvents = ($hashp->{lhs} . '$' => 1, 'translationUnit$' => 1);
  $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
                  (
                   description => $lhsProcessEvent,
                   method => [ $hashp->{method} ],
                   option => MarpaX::Languages::C::AST::Callback::Option->new
                   (
		    condition => [ [ 'auto' ] ],  # == match on description
                    topic => \%rhsTopicsNotToUpdate,
                    topic_persistence => 'level',
                    priority => 1,
                   )
                  )
                 );
  #
  # ... and reset rhs topic data
  #
  $callback->register(MarpaX::Languages::C::AST::Callback::Method->new
                  (
                   description => $lhsResetEvent,
                   method =>  [ \&_reset_helper, keys %rhsTopicsToUpdate ],
                   method_mode => 'replace',
                   option => MarpaX::Languages::C::AST::Callback::Option->new
                   (
		    condition => [ [ 'auto' ] ],  # == match on description
                    topic => \%rhsTopicsToUpdate,
                    topic_persistence => 'level',
                    priority => 0,
                   )
                  )
                 );

  #
  ## Sub-fire RHS processing events for this sub-callback object, except the <LHS$>
  ## that is done just after.
  #
  $self->register(MarpaX::Languages::C::AST::Callback::Method->new
                  (
                   description => $hashp->{lhs} . ' [intermediary events]',
                   method => [ \&_subFire, $hashp->{lhs}, $callback, \%rshProcessEvents ],
                   option => MarpaX::Languages::C::AST::Callback::Option->new
                   (
                    condition => [
                                  [ sub { my ($method, $callback, $eventsp, $processEventsp) = @_;
                                          return grep {exists($processEventsp->{$_})} @{$eventsp};
                                        },
                                    \%rshProcessEvents
                                  ]
                                 ],
                   )
                  )
                 );

  #
  ## For <LHS$> we distinguish the processing event and the reset event.
  ## Processing event can happen at a pre-defined priority because sometimes we
  ## want to fire the <LHS$> processing before a scope is closed.
  ## On the other hand, the reset will always happen after all scopes are
  ## closed.
  #
  $self->register(MarpaX::Languages::C::AST::Callback::Method->new
                  (
                   description => $lhsProcessEvent,
                   method => [ \&_subFire, $hashp->{lhs}, $callback, \%lhsProcessEvents, {$hashp->{lhs} . '$' => $lhsProcessEvent} ],
                   option => MarpaX::Languages::C::AST::Callback::Option->new
                   (
                    condition => [
                                  [ sub { my ($method, $callback, $eventsp, $processEventsp) = @_;
                                          return grep {exists($processEventsp->{$_})} @{$eventsp};
                                        },
                                    \%lhsProcessEvents
                                  ]
                                 ],
                    priority => $hashp->{process_priority} || 0
                   )
                  )
                 );
  #  $self->register(MarpaX::Languages::C::AST::Callback::Method->new
  #                 (
  #                  description => $lhsResetEvent,
  #                  method => [ \&_subFire, $hashp->{lhs}, $callback, \%lhsResetEvents, {$hashp->{lhs} . '$' => $lhsResetEvent, 'translationUnit$' => $lhsResetEvent} ],
  #                  option => MarpaX::Languages::C::AST::Callback::Option->new
  #                  (
  #                   condition => [
  #                                 [ sub { my ($method, $callback, $eventsp, $processEventsp) = @_;
  #                                         return grep {exists($processEventsp->{$_})} @{$eventsp};
  #                                       },
  #                                   \%lhsResetEvents
  #                                 ]
  #                                ],
  #                   priority => $hashp->{reset_priority}
  #                  )
  #                 )
  #                );

  return $callback;
}

1;
