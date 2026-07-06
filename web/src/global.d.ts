import "solid-js";

declare module "solid-js" {
  namespace JSX {
    interface ExplicitAttributes {
      mode: string;
    }
  }
}
