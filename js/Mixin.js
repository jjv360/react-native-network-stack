
//
// Tools for mixing class functions.

/**
 *  This class provides mixin functionality, allowing you to split up a class into multiple files.
 *
 *  To create a mixin, extend this class, then call `MyMixin.applyTo(MainClass)`.
 *  You can also do `Mixin.applyTo(MainClass, class { ... })
 */
export default class Mixin {

    /**
     *  Copies all property definitions onto the passed in class's prototype chain.
     */
    static applyTo(MainClass, Target) {

        // Use this is no target class
        if (!Target)
            Target = this

        // Sanity check: Ensure we were passed a class
        if (typeof Target != "function") throw new Error("Mixin.applyTo() was called with an invalid 'Target' or 'this' value.")
        if (typeof MainClass != "function") throw new Error("You must pass a class to Mixin.applyTo().")

        // Copy all normal properties onto the prototype chain
        let names = Object.getOwnPropertyNames(Target.prototype)
        for (let name of names) {

            // Ignore special cases
            if (name == "constructor")
                continue

            // Check it doesn't exist already
            if (Object.getOwnPropertyDescriptor(MainClass.prototype, name))
                throw new Error(`Mixins should not override existing functions or properties. Property '${name}' already exists.`)

            // Copy it over
            let descriptor = Object.getOwnPropertyDescriptor(Target.prototype, name)
            Object.defineProperty(MainClass.prototype, name, descriptor)

        }

        // Copy all static properties into the class
        names = Object.getOwnPropertyNames(Target)
        for (let name of names) {

            // Ignore special cases
            if (name == "constructor" || name == "length" || name == "prototype" || name == "name" || name == "arguments" || name == "caller")
                continue

            // Ignore this function
            if (name == "applyTo")
                continue

            // Check it doesn't exist already
            if (Object.getOwnPropertyDescriptor(MainClass, name))
                throw new Error(`Mixins should not override existing functions or properties. Static '${name}' already exists.`)

            // Copy it over
            let descriptor = Object.getOwnPropertyDescriptor(Target, name)
            Object.defineProperty(MainClass, name, descriptor)

        }

    }

}
