import type {SidebarsConfig} from '@docusaurus/plugin-content-docs';

const sidebars: SidebarsConfig = {
  docs: [
    'intro',
    {
      type: 'category',
      label: 'Python API',
      link: {type: 'doc', id: 'python-api/index'},
      items: [
        'python-api/pricing-engine',
        'python-api/credit-manager',
        'python-api/stores',
      ],
    },
    {
      type: 'category',
      label: 'JavaScript API',
      link: {type: 'doc', id: 'javascript-api/index'},
      items: [
        'javascript-api/pricing-engine',
        'javascript-api/credit-manager',
        'javascript-api/stores',
      ],
    },
    'expressions',
    'configuration',
    'storage-backends',
    'cli',
    'architecture',
  ],
};

export default sidebars;
