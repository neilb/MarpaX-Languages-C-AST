use strict;
use warnings FATAL => 'all';

package MarpaX::Languages::C::AST::Callback::Option;
use Class::Struct
    topic             => '%',        # Give topics for this callback.
    topic_persistence => '$',        # Give topic persistence for this callback.
    subscription      => '%',        # Give subscription topics.
    subscriptionMode  => '$',        # 'required' or 'optional'
    condition         => '@',        # Conditions. An array of CODE ref
    conditionMode     => '$',        # 'or' or 'and'
    priority          => '$',        # Priority.
    ;

# ABSTRACT: Options for the Simple callback generic framework.

use Carp qw/croak/;

# VERSION

=head1 DESCRIPTION

This module is describing the options for the Simple Callback framework. The new() supports these items:

=over

=item topic

A hash of topics. Value must be an integer. Any true value mean the topic is on. If corresponding callback has an associated method, then a reference to the return value of the method will be attached as a data to every topic, within an array reference. Take care: the return value of the eventual method will NOT be cloned when it is stored, neither when the topic level will change.

=item topic_persistence

A persistence for the raised topics. Value can be 'any', 'level' or 'none'. 'any' means that if a new level of topics is created, it will inherit all raised topics from this method. 'level' means that the topics raised by this method stay alive but will not be propaged to an eventual new level. 'none' means that a new level of topics will be inherit no topic from this method. Default is 'none'. Eventual topic data will follow the persistence.

=item subscription (to topics)

A hash of subscription (to topics). Key can be a topic or a regexp. Any true value mean the subscription is on.

=item subscriptionMode (to topics)

It can be 'required' or 'optional'. Default is 'required'. When the value is 'required', it acts a a filter to eventual condition: all subscribed topics must have been raised. Otherwise, the callback remain sligible if its condition is true and there would be no subscribed topic raised.

=item condition

An array of CODE refs, executed as condition requirements for the callback. Condition's arguments will be the reference to the callback object associated with these options followed by exec() arguments. If there is no condition, the callback can be eligible only via topic subscriptions. It is possible to specifiy the string "auto" instead of a CODE ref; then Callback will do a grep on the exec() arguments and compare it with the callback description. If there is something in the condition array, and if it returns false, callback will never be eligible, regardless if subscription to any topic would return true.

=item conditionMode

This is a string that can be 'xor', 'or' or 'and', driving all the conditions in the condition array. Default is 'or'.

=item priority

This is a number that gives the execution priority.

=back

=cut

1;
