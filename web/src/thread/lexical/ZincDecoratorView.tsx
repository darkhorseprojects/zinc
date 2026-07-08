import { Dynamic } from "solid-js/web";
import { resolveComponent } from "~/thread/components/registry";
import type { MdxComponentDecorator } from "~/thread/nodes";

export type ZincDecorator = MdxComponentDecorator;

export function ZincDecoratorView(props: { decorator: ZincDecorator }) {
  return <Dynamic component={resolveComponent(props.decorator.tag)} nodeKey={props.decorator.nodeKey} tag={props.decorator.tag} props={props.decorator.props} body={props.decorator.body} />;
}
