import { ButtonShapeModifier } from './ButtonShapeModifier'

// Text actions may wrap and grow; icon buttons and remote input surfaces keep their own geometry.
export class ReadableButtonModifier extends ButtonShapeModifier {
  applyNormalAttribute(instance: ButtonAttribute): void {
    super.applyNormalAttribute(instance)
    instance.labelStyle({
      overflow: TextOverflow.Clip,
      maxLines: 100,
      heightAdaptivePolicy: TextHeightAdaptivePolicy.MAX_LINES_FIRST
    })
  }
}
