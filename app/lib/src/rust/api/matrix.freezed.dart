// GENERATED CODE - DO NOT MODIFY BY HAND
// coverage:ignore-file
// ignore_for_file: type=lint
// ignore_for_file: unused_element, deprecated_member_use, deprecated_member_use_from_same_package, use_function_type_syntax_for_parameters, unnecessary_const, avoid_init_to_null, invalid_override_different_default_values_named, prefer_expression_function_bodies, annotate_overrides, invalid_annotation_target, unnecessary_question_mark

part of 'matrix.dart';

// **************************************************************************
// FreezedGenerator
// **************************************************************************

// dart format off
T _$identity<T>(T value) => value;
/// @nodoc
mixin _$SyncEvent {





@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent()';
}


}

/// @nodoc
class $SyncEventCopyWith<$Res>  {
$SyncEventCopyWith(SyncEvent _, $Res Function(SyncEvent) __);
}


/// Adds pattern-matching-related methods to [SyncEvent].
extension SyncEventPatterns on SyncEvent {
/// A variant of `map` that fallback to returning `orElse`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SyncEvent_Message value)?  message,TResult Function( SyncEvent_RoomsChanged value)?  roomsChanged,TResult Function( SyncEvent_Typing value)?  typing,TResult Function( SyncEvent_ReactionUpdated value)?  reactionUpdated,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged(_that);case SyncEvent_Typing() when typing != null:
return typing(_that);case SyncEvent_ReactionUpdated() when reactionUpdated != null:
return reactionUpdated(_that);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// Callbacks receives the raw object, upcasted.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case final Subclass2 value:
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SyncEvent_Message value)  message,required TResult Function( SyncEvent_RoomsChanged value)  roomsChanged,required TResult Function( SyncEvent_Typing value)  typing,required TResult Function( SyncEvent_ReactionUpdated value)  reactionUpdated,}){
final _that = this;
switch (_that) {
case SyncEvent_Message():
return message(_that);case SyncEvent_RoomsChanged():
return roomsChanged(_that);case SyncEvent_Typing():
return typing(_that);case SyncEvent_ReactionUpdated():
return reactionUpdated(_that);}
}
/// A variant of `map` that fallback to returning `null`.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case final Subclass value:
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SyncEvent_Message value)?  message,TResult? Function( SyncEvent_RoomsChanged value)?  roomsChanged,TResult? Function( SyncEvent_Typing value)?  typing,TResult? Function( SyncEvent_ReactionUpdated value)?  reactionUpdated,}){
final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged(_that);case SyncEvent_Typing() when typing != null:
return typing(_that);case SyncEvent_ReactionUpdated() when reactionUpdated != null:
return reactionUpdated(_that);case _:
  return null;

}
}
/// A variant of `when` that fallback to an `orElse` callback.
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return orElse();
/// }
/// ```

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( IncomingMessage field0)?  message,TResult Function()?  roomsChanged,TResult Function( RoomTypingUpdate field0)?  typing,TResult Function( String roomId,  String targetEventId,  String emoji,  String sender,  String reactionEventId,  bool removed)?  reactionUpdated,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that.field0);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged();case SyncEvent_Typing() when typing != null:
return typing(_that.field0);case SyncEvent_ReactionUpdated() when reactionUpdated != null:
return reactionUpdated(_that.roomId,_that.targetEventId,_that.emoji,_that.sender,_that.reactionEventId,_that.removed);case _:
  return orElse();

}
}
/// A `switch`-like method, using callbacks.
///
/// As opposed to `map`, this offers destructuring.
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case Subclass2(:final field2):
///     return ...;
/// }
/// ```

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( IncomingMessage field0)  message,required TResult Function()  roomsChanged,required TResult Function( RoomTypingUpdate field0)  typing,required TResult Function( String roomId,  String targetEventId,  String emoji,  String sender,  String reactionEventId,  bool removed)  reactionUpdated,}) {final _that = this;
switch (_that) {
case SyncEvent_Message():
return message(_that.field0);case SyncEvent_RoomsChanged():
return roomsChanged();case SyncEvent_Typing():
return typing(_that.field0);case SyncEvent_ReactionUpdated():
return reactionUpdated(_that.roomId,_that.targetEventId,_that.emoji,_that.sender,_that.reactionEventId,_that.removed);}
}
/// A variant of `when` that fallback to returning `null`
///
/// It is equivalent to doing:
/// ```dart
/// switch (sealedClass) {
///   case Subclass(:final field):
///     return ...;
///   case _:
///     return null;
/// }
/// ```

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( IncomingMessage field0)?  message,TResult? Function()?  roomsChanged,TResult? Function( RoomTypingUpdate field0)?  typing,TResult? Function( String roomId,  String targetEventId,  String emoji,  String sender,  String reactionEventId,  bool removed)?  reactionUpdated,}) {final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that.field0);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged();case SyncEvent_Typing() when typing != null:
return typing(_that.field0);case SyncEvent_ReactionUpdated() when reactionUpdated != null:
return reactionUpdated(_that.roomId,_that.targetEventId,_that.emoji,_that.sender,_that.reactionEventId,_that.removed);case _:
  return null;

}
}

}

/// @nodoc


class SyncEvent_Message extends SyncEvent {
  const SyncEvent_Message(this.field0): super._();
  

 final  IncomingMessage field0;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_MessageCopyWith<SyncEvent_Message> get copyWith => _$SyncEvent_MessageCopyWithImpl<SyncEvent_Message>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_Message&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SyncEvent.message(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_MessageCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_MessageCopyWith(SyncEvent_Message value, $Res Function(SyncEvent_Message) _then) = _$SyncEvent_MessageCopyWithImpl;
@useResult
$Res call({
 IncomingMessage field0
});




}
/// @nodoc
class _$SyncEvent_MessageCopyWithImpl<$Res>
    implements $SyncEvent_MessageCopyWith<$Res> {
  _$SyncEvent_MessageCopyWithImpl(this._self, this._then);

  final SyncEvent_Message _self;
  final $Res Function(SyncEvent_Message) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SyncEvent_Message(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as IncomingMessage,
  ));
}


}

/// @nodoc


class SyncEvent_RoomsChanged extends SyncEvent {
  const SyncEvent_RoomsChanged(): super._();
  






@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_RoomsChanged);
}


@override
int get hashCode => runtimeType.hashCode;

@override
String toString() {
  return 'SyncEvent.roomsChanged()';
}


}




/// @nodoc


class SyncEvent_Typing extends SyncEvent {
  const SyncEvent_Typing(this.field0): super._();
  

 final  RoomTypingUpdate field0;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_TypingCopyWith<SyncEvent_Typing> get copyWith => _$SyncEvent_TypingCopyWithImpl<SyncEvent_Typing>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_Typing&&(identical(other.field0, field0) || other.field0 == field0));
}


@override
int get hashCode => Object.hash(runtimeType,field0);

@override
String toString() {
  return 'SyncEvent.typing(field0: $field0)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_TypingCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_TypingCopyWith(SyncEvent_Typing value, $Res Function(SyncEvent_Typing) _then) = _$SyncEvent_TypingCopyWithImpl;
@useResult
$Res call({
 RoomTypingUpdate field0
});




}
/// @nodoc
class _$SyncEvent_TypingCopyWithImpl<$Res>
    implements $SyncEvent_TypingCopyWith<$Res> {
  _$SyncEvent_TypingCopyWithImpl(this._self, this._then);

  final SyncEvent_Typing _self;
  final $Res Function(SyncEvent_Typing) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? field0 = null,}) {
  return _then(SyncEvent_Typing(
null == field0 ? _self.field0 : field0 // ignore: cast_nullable_to_non_nullable
as RoomTypingUpdate,
  ));
}


}

/// @nodoc


class SyncEvent_ReactionUpdated extends SyncEvent {
  const SyncEvent_ReactionUpdated({required this.roomId, required this.targetEventId, required this.emoji, required this.sender, required this.reactionEventId, required this.removed}): super._();
  

 final  String roomId;
 final  String targetEventId;
 final  String emoji;
 final  String sender;
 final  String reactionEventId;
 final  bool removed;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@JsonKey(includeFromJson: false, includeToJson: false)
@pragma('vm:prefer-inline')
$SyncEvent_ReactionUpdatedCopyWith<SyncEvent_ReactionUpdated> get copyWith => _$SyncEvent_ReactionUpdatedCopyWithImpl<SyncEvent_ReactionUpdated>(this, _$identity);



@override
bool operator ==(Object other) {
  return identical(this, other) || (other.runtimeType == runtimeType&&other is SyncEvent_ReactionUpdated&&(identical(other.roomId, roomId) || other.roomId == roomId)&&(identical(other.targetEventId, targetEventId) || other.targetEventId == targetEventId)&&(identical(other.emoji, emoji) || other.emoji == emoji)&&(identical(other.sender, sender) || other.sender == sender)&&(identical(other.reactionEventId, reactionEventId) || other.reactionEventId == reactionEventId)&&(identical(other.removed, removed) || other.removed == removed));
}


@override
int get hashCode => Object.hash(runtimeType,roomId,targetEventId,emoji,sender,reactionEventId,removed);

@override
String toString() {
  return 'SyncEvent.reactionUpdated(roomId: $roomId, targetEventId: $targetEventId, emoji: $emoji, sender: $sender, reactionEventId: $reactionEventId, removed: $removed)';
}


}

/// @nodoc
abstract mixin class $SyncEvent_ReactionUpdatedCopyWith<$Res> implements $SyncEventCopyWith<$Res> {
  factory $SyncEvent_ReactionUpdatedCopyWith(SyncEvent_ReactionUpdated value, $Res Function(SyncEvent_ReactionUpdated) _then) = _$SyncEvent_ReactionUpdatedCopyWithImpl;
@useResult
$Res call({
 String roomId, String targetEventId, String emoji, String sender, String reactionEventId, bool removed
});




}
/// @nodoc
class _$SyncEvent_ReactionUpdatedCopyWithImpl<$Res>
    implements $SyncEvent_ReactionUpdatedCopyWith<$Res> {
  _$SyncEvent_ReactionUpdatedCopyWithImpl(this._self, this._then);

  final SyncEvent_ReactionUpdated _self;
  final $Res Function(SyncEvent_ReactionUpdated) _then;

/// Create a copy of SyncEvent
/// with the given fields replaced by the non-null parameter values.
@pragma('vm:prefer-inline') $Res call({Object? roomId = null,Object? targetEventId = null,Object? emoji = null,Object? sender = null,Object? reactionEventId = null,Object? removed = null,}) {
  return _then(SyncEvent_ReactionUpdated(
roomId: null == roomId ? _self.roomId : roomId // ignore: cast_nullable_to_non_nullable
as String,targetEventId: null == targetEventId ? _self.targetEventId : targetEventId // ignore: cast_nullable_to_non_nullable
as String,emoji: null == emoji ? _self.emoji : emoji // ignore: cast_nullable_to_non_nullable
as String,sender: null == sender ? _self.sender : sender // ignore: cast_nullable_to_non_nullable
as String,reactionEventId: null == reactionEventId ? _self.reactionEventId : reactionEventId // ignore: cast_nullable_to_non_nullable
as String,removed: null == removed ? _self.removed : removed // ignore: cast_nullable_to_non_nullable
as bool,
  ));
}


}

// dart format on
