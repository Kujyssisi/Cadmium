#pragma once

/// The state of the keyboard itself, rather than what anyone believes about it.
///
/// Godot knows a key is down because it was told, and it is told by whoever has
/// the keyboard. A plugin's own interface takes the keyboard the moment it is
/// clicked, so the key-up is delivered there and Godot goes on believing the
/// key is held for ever -- which is a note that sounds until Cadmium is closed.
/// Nothing on the Godot side can see that, because the thing it would have to
/// ask is the thing that is wrong.
namespace cd {

/// Whether any key at all is physically down, asked of the window system.
///
/// Deliberately the weakest question that solves the problem: it says nothing
/// about *which* key, so it can only ever release a note when the keyboard is
/// completely idle, and it can never cut off a key somebody is still holding.
///
/// Answers true when it cannot find out -- no display, an unsupported platform,
/// a failed call -- because "assume it is still held" leaves Cadmium behaving
/// exactly as it did before this existed. Mouse buttons are not keys.
bool any_key_held();

}  // namespace cd
