// Rewrite the package reference while preserving this comment.
import helper from "old-package";
export { helper } from "old-package";

export function greet(name) {
  return `Hello, ${helper(name)}!`;
}
