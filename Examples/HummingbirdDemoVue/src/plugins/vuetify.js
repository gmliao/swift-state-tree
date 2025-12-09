import "vuetify/styles";
import "@mdi/font/css/materialdesignicons.css";
import { createVuetify } from "vuetify";
import * as components from "vuetify/components";
import * as directives from "vuetify/directives";
// Enable core Vuetify components/directives so <v-*> tags resolve correctly.
const vuetify = createVuetify({
    components,
    directives,
});
export default vuetify;
