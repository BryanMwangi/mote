// Where the selection sits on the page (the passage around it, the heading
// over it), for the assistant when asked about a selection. Called from Swift
// (Tab.selectionPlace) in the default client content world.

import { type SelectionPlace, selectionPlace } from './selected-text/place';

export function run(): SelectionPlace | null {
  return selectionPlace(document);
}
