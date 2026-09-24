# Capability: viewport

`set({ width, height })` renders pages at that size; `reset()` goes back to fitting the live
view. Use it only for responsive testing or when the user asks for a size, and reset it when
done. Don't resize to make screenshots bigger; use `fullPage` screenshots instead.
