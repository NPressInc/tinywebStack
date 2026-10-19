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

@optionalTypeArgs TResult maybeMap<TResult extends Object?>({TResult Function( SyncEvent_Message value)?  message,TResult Function( SyncEvent_RoomsChanged value)?  roomsChanged,required TResult orElse(),}){
final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged(_that);case _:
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

@optionalTypeArgs TResult map<TResult extends Object?>({required TResult Function( SyncEvent_Message value)  message,required TResult Function( SyncEvent_RoomsChanged value)  roomsChanged,}){
final _that = this;
switch (_that) {
case SyncEvent_Message():
return message(_that);case SyncEvent_RoomsChanged():
return roomsChanged(_that);}
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

@optionalTypeArgs TResult? mapOrNull<TResult extends Object?>({TResult? Function( SyncEvent_Message value)?  message,TResult? Function( SyncEvent_RoomsChanged value)?  roomsChanged,}){
final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged(_that);case _:
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

@optionalTypeArgs TResult maybeWhen<TResult extends Object?>({TResult Function( IncomingMessage field0)?  message,TResult Function()?  roomsChanged,required TResult orElse(),}) {final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that.field0);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged();case _:
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

@optionalTypeArgs TResult when<TResult extends Object?>({required TResult Function( IncomingMessage field0)  message,required TResult Function()  roomsChanged,}) {final _that = this;
switch (_that) {
case SyncEvent_Message():
return message(_that.field0);case SyncEvent_RoomsChanged():
return roomsChanged();}
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

@optionalTypeArgs TResult? whenOrNull<TResult extends Object?>({TResult? Function( IncomingMessage field0)?  message,TResult? Function()?  roomsChanged,}) {final _that = this;
switch (_that) {
case SyncEvent_Message() when message != null:
return message(_that.field0);case SyncEvent_RoomsChanged() when roomsChanged != null:
return roomsChanged();case _:
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




// dart format on
